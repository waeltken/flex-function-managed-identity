terraform {
  required_version = ">= 1.6, < 2.0"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.13"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}

provider "azapi" {
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  description = "Azure subscription in which to create the demo resources."
  type        = string
}

variable "blob_reader_object_id" {
  description = "Microsoft Entra object ID of the user granted read-only access to all blobs in the demo storage account."
  type        = string
}

variable "resource_group_tags" {
  description = "Additional resource-group tags for the deployment environment."
  type        = map(string)
  default     = {}
}

variable "location" {
  description = "Azure region supporting Flex Consumption and the selected runtime."
  type        = string
  default     = "swedencentral"
}

variable "runtime_name" {
  description = "Flex Consumption language runtime; must match the deployed application."
  type        = string
  default     = "python"
}

variable "runtime_version" {
  description = "Version supported by the selected Flex Consumption language runtime."
  type        = string
  default     = "3.13"
}

locals {
  tags = {
    project     = "functions-demo"
    environment = "demo"
    managed_by  = "terraform"
  }
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "azurerm_resource_group" "demo" {
  name     = "functions-demo-rg"
  location = var.location
  tags     = merge(local.tags, var.resource_group_tags)
}

# One account per Function App: host state and a separate deployment container.
resource "azurerm_storage_account" "functions" {
  name                            = "funcsdemo${random_id.suffix.hex}"
  resource_group_name             = azurerm_resource_group.demo.name
  location                        = azurerm_resource_group.demo.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  public_network_access           = "Enabled"
  tags                            = local.tags
}

resource "azurerm_storage_container" "deployment" {
  name                  = "deployment-packages"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "user_blob_reader" {
  scope                = azurerm_storage_account.functions.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.blob_reader_object_id
  principal_type       = "User"
}

# A user-assigned identity can receive permissions before the app is created.
resource "azurerm_user_assigned_identity" "functions" {
  name                = "functions-demo-mi"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  tags                = local.tags
}

# Required for host blobs/leases/keys. This also includes the Blob Data
# Contributor permissions required for deployment packages in the same account.
resource "azurerm_role_assignment" "host_blobs" {
  scope                            = azurerm_storage_account.functions.id
  role_definition_name             = "Storage Blob Data Owner"
  principal_id                     = azurerm_user_assigned_identity.functions.principal_id
  skip_service_principal_aad_check = true
}

# Host diagnostic events are persisted to Table Storage.
resource "azurerm_role_assignment" "host_diagnostics" {
  scope                            = azurerm_storage_account.functions.id
  role_definition_name             = "Storage Table Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.functions.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_service_plan" "functions" {
  name                = "functions-demo-plan"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

resource "azurerm_log_analytics_workspace" "functions" {
  name                = "functions-demo-logs"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "functions" {
  name                = "functions-demo-insights"
  resource_group_name = azurerm_resource_group.demo.name
  location            = azurerm_resource_group.demo.location
  workspace_id        = azurerm_log_analytics_workspace.functions.id
  application_type    = "web"
  tags                = local.tags
}

# Use AzAPI to avoid AzureRM's automatic account-key AzureWebJobsStorage
# injection: https://github.com/hashicorp/terraform-provider-azurerm/issues/29149
resource "azapi_resource" "functions" {
  type      = "Microsoft.Web/sites@2024-04-01"
  name      = "functions-demo-${random_id.suffix.hex}"
  parent_id = azurerm_resource_group.demo.id
  location  = azurerm_resource_group.demo.location
  tags      = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.functions.id]
  }

  body = {
    kind = "functionapp,linux"
    properties = {
      serverFarmId        = azurerm_service_plan.functions.id
      reserved            = true
      httpsOnly           = true
      publicNetworkAccess = "Enabled"

      # Deployment storage authentication is independent of AzureWebJobsStorage.
      functionAppConfig = {
        deployment = {
          storage = {
            type  = "blobContainer"
            value = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
            authentication = {
              type                           = "UserAssignedIdentity"
              userAssignedIdentityResourceId = azurerm_user_assigned_identity.functions.id
            }
          }
        }
        runtime = {
          name    = var.runtime_name
          version = var.runtime_version
        }
        scaleAndConcurrency = {
          maximumInstanceCount = 50
          instanceMemoryMB     = 2048
        }
      }

      siteConfig = {
        minTlsVersion = "1.2"
        # These three properties collectively define AzureWebJobsStorage.
        # Do not also set an unprefixed account-key connection string.
        appSettings = [
          {
            name  = "AzureWebJobsStorage__accountName"
            value = azurerm_storage_account.functions.name
          },
          {
            name  = "AzureWebJobsStorage__credential"
            value = "managedidentity"
          },
          {
            name  = "AzureWebJobsStorage__clientId"
            value = azurerm_user_assigned_identity.functions.client_id
          },
          {
            name  = "APPLICATIONINSIGHTS_CONNECTION_STRING"
            value = azurerm_application_insights.functions.connection_string
          },
        ]
      }
    }
  }

  response_export_values = ["properties.defaultHostName"]

  depends_on = [
    azurerm_role_assignment.host_blobs,
    azurerm_role_assignment.host_diagnostics,
  ]
}

output "resource_group_name" {
  description = "Resource group containing all demo Azure resources."
  value       = azurerm_resource_group.demo.name
}

output "function_app_name" {
  description = "Function App to target when publishing application code."
  value       = azapi_resource.functions.name
}

output "function_app_url" {
  description = "Function App base URL; function routes depend on the deployed code."
  value       = "https://${azapi_resource.functions.output.properties.defaultHostName}"
}

output "storage_account_name" {
  description = "Storage account used for AzureWebJobsStorage and deployment packages."
  value       = azurerm_storage_account.functions.name
}

output "deployment_container_url" {
  description = "Private Blob container configured as Flex deployment storage."
  value       = "${azurerm_storage_account.functions.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
}

output "managed_identity_client_id" {
  description = "User-assigned identity client ID selected by AzureWebJobsStorage."
  value       = azurerm_user_assigned_identity.functions.client_id
}

output "managed_identity_principal_id" {
  description = "User-assigned identity principal ID used in storage role assignments."
  value       = azurerm_user_assigned_identity.functions.principal_id
}
