# Azure Functions Flex Consumption demo

`main.tf` provisions one Function App and its supporting resources in
`functions-demo-rg`. This project uses **Flex Consumption** on Linux with SKU
**FC1**, not classic Consumption (`Y1` / `Dynamic`).
The default runtime is Python 3.13, in Sweden Central. `app/` contains a minimal
FastAPI application using the Azure Functions Python v2 programming model.

## Resources

| Resource | Purpose |
| --- | --- |
| Resource group `functions-demo-rg` | Contains all demo Azure resources. |
| Linux Flex Consumption service plan (`FC1`) | On-demand execution; no always-ready instances configured. |
| Function App `functions-demo-<suffix>` | Application hosting, HTTPS only, 2,048 MB instances, maximum 50 instances. |
| Standard LRS general-purpose v2 storage account | Runtime host storage, supporting blobs, queues, and tables. Shared-key authentication and anonymous Blob access are disabled. |
| Private Blob container `deployment-packages` | Flex deployment packages, separate from runtime-managed host containers. |
| User-assigned managed identity `functions-demo-mi` | Explicit identity for both host storage and deployment storage. |
| Storage Blob Data Owner role assignment | Host state, leases, and function keys; also includes the Blob Data Contributor permissions needed for deployment storage in the same account. |
| Storage Table Data Contributor role assignment | Host diagnostic events. |
| Application Insights and Log Analytics workspace | Recommended monitoring, including host startup and storage errors. |

A random suffix provides globally unique candidate names for the storage account
and Function App. This is a single-app demo: do not deploy multiple apps against
the same deployment container. Use a separate account per app where practical, and a
separate deployment container per app if sharing an account.

## What AzureWebJobsStorage is

`AzureWebJobsStorage` is the Functions host's **storage connection configuration**,
not an Azure resource or a storage account that must have that name. The host
uses the referenced account for internal state, coordination, timer leases, and
function access keys. Some extensions also use it for checkpoints or Durable
Functions state. It is required even when application code does not use storage.

This project configures an identity-based connection using these app settings:

```text
AzureWebJobsStorage__accountName = <storage account name>
AzureWebJobsStorage__credential  = managedidentity
AzureWebJobsStorage__clientId    = <user-assigned identity client ID>
```

The absence of an exact `AzureWebJobsStorage` setting is therefore intentional:
the prefixed settings collectively define the connection. The client ID selects
the identity; its principal ID is used for RBAC assignments. Attaching an identity
without granting storage permissions is insufficient.

**Deployment storage is configured independently**, under
`properties.functionAppConfig.deployment.storage`. It references the private
container and selects `UserAssignedIdentity` with the identity's resource ID.
Configuring only this deployment connection does not configure host storage.

No storage connection strings, account keys, Azure Files share,
`WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`, or `WEBSITE_RUN_FROM_PACKAGE` are
configured. Flex handles package deployment through OneDeploy rather than the
classic Consumption content-share model. The Application Insights connection
string is telemetry configuration, not a storage connection string.

The base roles cover host storage and diagnostics. Add application-specific
permissions only when needed: for example, Durable Functions using this account
also needs Storage Queue Data Contributor; Blob-trigger extensions can require
additional queue and management-plane permissions. Use identity-capable binding
extension versions and explicit connections appropriate to the application.

### Why the Function App uses AzAPI

AzureRM 5.10.0 still constructs an unprefixed `AzureWebJobsStorage` connection
string for its Flex resource even when deployment storage uses managed identity.
With no supplied key, that connection string contains an empty account key and
can override the identity-based host settings. See
[AzureRM issue #29149](https://github.com/hashicorp/terraform-provider-azurerm/issues/29149).

This project creates the Function App directly through `azapi_resource` using
`Microsoft.Web/sites@2024-04-01`, with explicit host settings and deployment
authentication. AzureRM manages the supporting resources. There is no second
resource patching the same app, manual setting deletion, or ignored-settings
workaround. This avoids the provider behavior in the demo.

## Deploy

Prerequisites:

- Terraform 1.6 or later, Azure CLI, and an Azure subscription.
- Permissions to create the resource group and resources, attach the managed
  identity, and create role assignments. Contributor alone cannot assign roles;
  Owner, or Contributor plus User Access Administrator at the appropriate scope,
  are common options.
- The Terraform/deployment operator is distinct from the Function App identity.
  Storage data-plane operations require the operator's own Blob data permissions;
  the app's role assignments do not grant permissions to the operator.
  Set `blob_reader_object_id` in your local `terraform.tfvars` to your Microsoft
  Entra user object ID (`az ad signed-in-user show --query id -o tsv`). Terraform
  grants that user **Storage Blob Data Reader** across this storage account,
  including all containers, without blob write/delete permissions. Use
  `--auth-mode login` with Azure Storage CLI commands; new RBAC grants can take
  several minutes to propagate.
- A region and runtime supported by Flex Consumption. Check with
  `az functionapp list-flexconsumption-locations` and
  `az functionapp list-flexconsumption-runtimes --location swedencentral --runtime python`.
- Registered resource providers: `Microsoft.Web`, `Microsoft.Storage`,
  `Microsoft.ManagedIdentity`, `Microsoft.Insights`, and
  `Microsoft.OperationalInsights`. Automatic registration is disabled so a plan
  does not register providers. If necessary, an authorized administrator can run
  `az provider register --namespace <provider> --wait` for each provider.

```bash
az login
az account set --subscription <subscription-id>
export TF_VAR_subscription_id="$(az account show --query id --output tsv)"

terraform init
terraform plan -out=demo.tfplan
terraform apply demo.tfplan
terraform output
```

Keep `.terraform.lock.hcl` in version control. Local state, variable files, and
saved plans are ignored. Treat state and plans as sensitive: providers can retain
credentials even when the app uses managed identity. Configure a secured remote
backend before team or production use. Storage and monitoring can incur costs
independently of function executions.

The app depends on its role assignments, but Azure RBAC propagation is eventually
consistent. A newly created role assignment is not proof that the runtime can
already use it. This demo uses public storage endpoints with authenticated access
and public Function App ingress; it intentionally does not introduce VNets,
private endpoints, or storage firewall restrictions.

When reusing an app created for another language, verify the remote build runtime
as well as ARM's `functionAppConfig.runtime`. In this demo, changing Node.js 24 to
Python 3.13 in place and restarting still left OneDeploy building for Node.js.
The demo app had to be recreated with Python selected at creation. Deleting the
app also removed its Flex plan; a fresh Terraform refresh/apply recreated both.
The existing storage account and user-assigned identity were preserved. Treat
such a recreation as destructive and approve it explicitly before proceeding.

## Deployment environment

Organizational policies can restrict public network access and prevent this demo
from deploying or running unchanged. Use an approved network configuration; VNet
integration, storage private endpoints, and private DNS are outside this demo's
scope.

Optional `resource_group_tags` are merged with the demo's base resource-group tags,
with supplied values taking precedence. Keep environment-specific values in the
ignored `terraform.tfvars`, rather than hard-coding them in the shared source.
Terraform manages these tags on each apply.

## Publish and verify the application

`app/function_app.py` exposes one anonymous `GET /` route through
`azure.functions.AsgiFunctionApp`. `app/host.json` removes the default `/api`
prefix. The response is:

```json
{"message":"Hello from FastAPI on Azure Functions!"}
```

Use **uv** for dependency management. `app/pyproject.toml` and `app/uv.lock` are
the source of truth; `app/requirements.txt` is generated for Azure's remote
build. Do not edit the generated requirements independently. From the repository
root, with the intended Azure subscription selected:

```bash
uv sync --project app --locked
uv export --project app --frozen --no-dev --no-editable \
  --format requirements-txt --output-file app/requirements.txt

mkdir -p dist
zip -j dist/function-app.zip app/function_app.py app/host.json app/requirements.txt

az functionapp deployment source config-zip \
  --resource-group "$(terraform output -raw resource_group_name)" \
  --name "$(terraform output -raw function_app_name)" \
  --src dist/function-app.zip \
  --build-remote true \
  --timeout 600

curl --fail-with-body "$(terraform output -raw function_app_url)/"
```

The ZIP has `host.json`, `function_app.py`, and `requirements.txt` at its root,
not nested inside `app/`. It excludes the local virtual environment, Terraform
state, and credentials. `--build-remote true` lets Azure install the locked
dependencies for its Linux/Python runtime; no local binaries or Uvicorn server
are needed. On Flex, the Azure CLI routes this command through OneDeploy.

A successful package upload alone does not prove runtime health. Check the JSON
response above and use Application Insights for host startup or trigger errors.
The anonymous route is intentionally public and returns no sensitive data.

Verified on 2026-10-20: `config-zip --build-remote true` completed successfully.
`GET https://<function-app-name>.azurewebsites.net/` returned HTTP 200 with
`Content-Type: application/json` and the response shown above. The registered
ASGI handler also returned the same response in a local uv-managed smoke run.

For a failure, capture the earliest error, UTC timestamp, selected identity,
storage service endpoint, failing operation, and resulting app settings. Confirm
that there is no unprefixed account-key `AzureWebJobsStorage` setting overriding
the identity configuration. Distinguish deployment-package access from host
storage access and from application-specific connections.

## Documentation

- [AzureWebJobsStorage app setting and identity properties](https://learn.microsoft.com/en-us/azure/azure-functions/functions-app-settings#azurewebjobsstorage)
- [Storage considerations for Azure Functions](https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations)
- [Identity-based host connections and required permissions](https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host#define-connections)
- [Flex Consumption deployment storage configuration](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-how-to#configure-deployment-settings)
- [Flex Consumption plan](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan)
- [Microsoft.Web/sites ARM and Terraform AzAPI schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/sites)
