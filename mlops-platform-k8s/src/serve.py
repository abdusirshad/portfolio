import os
import mlflow.pyfunc
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.responses import Response
import time

app = FastAPI(title="MLOps Model Serving API", version="1.0.0")

# Load model from MLflow registry at startup
model = mlflow.pyfunc.load_model(
    model_uri=f"models:/{os.environ['MODEL_NAME']}/Production"
)

# Prometheus metrics
PREDICTION_COUNT = Counter("predictions_total", "Total predictions", ["status"])
PREDICTION_LATENCY = Histogram("prediction_latency_seconds", "Prediction latency")


class PredictRequest(BaseModel):
    features: list[float]


class PredictResponse(BaseModel):
    prediction: float
    model_version: str
    run_id: str
    latency_ms: float


@app.post("/predict", response_model=PredictResponse)
async def predict(request: PredictRequest):
    start = time.time()
    try:
        result = model.predict([request.features])
        latency = (time.time() - start) * 1000
        PREDICTION_COUNT.labels(status="success").inc()
        PREDICTION_LATENCY.observe(latency / 1000)
        return PredictResponse(
            prediction=float(result[0]),
            model_version=os.environ.get("MODEL_VERSION", "unknown"),
            run_id=os.environ.get("MLFLOW_RUN_ID", "unknown"),
            latency_ms=round(latency, 2),
        )
    except Exception as e:
        PREDICTION_COUNT.labels(status="error").inc()
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/health")
def health():
    return {"status": "healthy", "model": os.environ.get("MODEL_NAME")}


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
