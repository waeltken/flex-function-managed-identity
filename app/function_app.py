import azure.functions as func
from fastapi import FastAPI

api = FastAPI()


@api.get("/")
async def hello() -> dict[str, str]:
    return {"message": "Hello from FastAPI on Azure Functions!"}


app = func.AsgiFunctionApp(app=api, http_auth_level=func.AuthLevel.ANONYMOUS)
