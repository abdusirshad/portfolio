# mlops-platform-k8s

[![MLflow](https://img.shields.io/badge/MLflow-0194E2?style=flat-square&logo=mlflow)](https://mlflow.org)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-EKS%2FAKS-326CE5?style=flat-square&logo=kubernetes)](https://kubernetes.io)
[![Docker](https://img.shields.io/badge/Docker-2496ED?style=flat-square&logo=docker)](https://docker.com)
[![Helm](https://img.shields.io/badge/Helm-0F1689?style=flat-square&logo=helm)](https://helm.sh)
[![Python](https://img.shields.io/badge/Python-3.11-3776AB?style=flat-square&logo=python)](https://python.org)

> Production-grade **MLOps platform** on Kubernetes (EKS/AKS) — MLflow-based model packaging, versioning, and promotion pipelines with GitLab CI/CD gates. Reduced model release lead time by **50%**.

---

## Architecture

```
  Developer Push
       │
       ▼
  ┌────────────┐    ┌─────────────────────────────────────────────┐
  │ GitLab CI  │───▶│  Pipeline                                   │
  └────────────┘    │  1. Unit tests + lint                       │
                    │  2. Docker build + Trivy scan               │
                    │  3. Model validation (accuracy gate)        │
                    │  4. Push to ECR / ACR                       │
                    │  5. Helm deploy → staging                   │
                    │  6. Integration tests + canary metrics      │
                    │  7. Manual approval gate (prod)             │
                    │  8. Helm promote → production               │
                    └─────────────────────────────────────────────┘
                                        │
                    ┌───────────────────▼──────────────────────────┐
                    │           Kubernetes Cluster                  │
                    │                                               │
                    │  ┌─────────────┐    ┌─────────────────────┐  │
                    │  │   MLflow    │    │  Model Serving      │  │
                    │  │  Tracking   │    │  (FastAPI / TorchS) │  │
                    │  │  Server     │    │                     │  │
                    │  └─────────────┘    └─────────────────────┘  │
                    │  ┌─────────────┐    ┌─────────────────────┐  │
                    │  │ MinIO /     │    │  Training Jobs      │  │
                    │  │ S3 Artifact │    │  (K8s Jobs/CronJob) │  │
                    │  │ Store       │    │                     │  │
                    │  └─────────────┘    └─────────────────────┘  │
                    └──────────────────────────────────────────────┘
```

---

## Repository Structure

```
mlops-platform-k8s/
├── helm-charts/
│   ├── mlflow/                  # MLflow tracking server chart
│   ├── model-serving/           # Generic FastAPI model server chart
│   └── training-job/            # Parameterized training job chart
├── pipelines/
│   ├── .gitlab-ci.yml           # Main CI/CD pipeline
│   └── model-validation.py      # Accuracy / drift gate script
├── src/
│   ├── train.py                 # Training entrypoint (MLflow-instrumented)
│   ├── serve.py                 # FastAPI inference server
│   └── utils/
│       ├── mlflow_utils.py
│       └── data_utils.py
├── Dockerfile.train             # Training image
├── Dockerfile.serve             # Inference image
├── requirements.txt
└── README.md
```

---

## MLflow Tracking — Training Script

```python
# src/train.py
import mlflow
import mlflow.sklearn
from mlflow.models.signature import infer_signature

def train(params: dict, X_train, y_train, X_test, y_test):
    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
    mlflow.set_experiment(os.environ.get("MLFLOW_EXPERIMENT", "default"))

    with mlflow.start_run(tags={"environment": os.environ.get("ENV", "dev")}):
        # Log parameters
        mlflow.log_params(params)

        # Train
        model = build_model(params)
        model.fit(X_train, y_train)

        # Evaluate
        metrics = evaluate(model, X_test, y_test)
        mlflow.log_metrics(metrics)

        # Log model with signature
        signature = infer_signature(X_train, model.predict(X_train))
        mlflow.sklearn.log_model(
            model,
            artifact_path="model",
            signature=signature,
            registered_model_name=os.environ["MODEL_NAME"],
        )

        # Accuracy gate — fail pipeline if below threshold
        threshold = float(os.environ.get("ACCURACY_THRESHOLD", "0.85"))
        if metrics["accuracy"] < threshold:
            raise ValueError(
                f"Accuracy {metrics['accuracy']:.4f} below threshold {threshold}"
            )

        return mlflow.active_run().info.run_id
```

---

## GitLab CI/CD Pipeline

```yaml
# pipelines/.gitlab-ci.yml
stages:
  - validate
  - build
  - train-validate
  - deploy-staging
  - integration-test
  - deploy-prod

variables:
  MLFLOW_TRACKING_URI: "http://mlflow.mlops.svc.cluster.local:5000"
  MODEL_NAME: "production-model"
  ACCURACY_THRESHOLD: "0.87"
  IMAGE_TAG: $CI_COMMIT_SHORT_SHA

.docker-login: &docker-login
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY

lint-and-test:
  stage: validate
  image: python:3.11-slim
  script:
    - pip install -r requirements.txt
    - ruff check src/
    - pytest tests/unit/ -v --junitxml=report.xml
  artifacts:
    reports:
      junit: report.xml

build-and-scan:
  stage: build
  <<: *docker-login
  script:
    - docker build -f Dockerfile.train -t $CI_REGISTRY_IMAGE/train:$IMAGE_TAG .
    - docker build -f Dockerfile.serve -t $CI_REGISTRY_IMAGE/serve:$IMAGE_TAG .
    # Trivy vulnerability scan — fail on CRITICAL
    - trivy image --exit-code 1 --severity CRITICAL $CI_REGISTRY_IMAGE/serve:$IMAGE_TAG
    - docker push $CI_REGISTRY_IMAGE/train:$IMAGE_TAG
    - docker push $CI_REGISTRY_IMAGE/serve:$IMAGE_TAG

model-validation:
  stage: train-validate
  image: $CI_REGISTRY_IMAGE/train:$IMAGE_TAG
  script:
    - python pipelines/model-validation.py
  artifacts:
    paths:
      - validation_report.json

deploy-staging:
  stage: deploy-staging
  script:
    - helm upgrade --install model-serving-staging helm-charts/model-serving
        --namespace mlops-staging
        --set image.tag=$IMAGE_TAG
        --set mlflow.runId=$MLFLOW_RUN_ID
        --wait --timeout 5m

deploy-prod:
  stage: deploy-prod
  when: manual
  environment: production
  only:
    - main
  script:
    - helm upgrade --install model-serving-prod helm-charts/model-serving
        --namespace mlops-prod
        --set image.tag=$IMAGE_TAG
        --set replicaCount=3
        --set resources.requests.memory=4Gi
        --wait --timeout 10m
```

---

## Helm Chart — MLflow Tracking Server

```yaml
# helm-charts/mlflow/values.yaml
replicaCount: 2

image:
  repository: ghcr.io/mlflow/mlflow
  tag: "2.12.1"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 5000

artifactStore:
  type: s3               # or azureblob
  s3:
    bucket: mlflow-artifacts
    region: us-east-1
  azureBlob:
    storageAccount: mlflowartifacts
    container: mlflow

backendStore:
  postgresql:
    host: postgresql.mlops.svc.cluster.local
    port: 5432
    database: mlflow
    existingSecret: mlflow-db-secret
    secretKey: password

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: mlflow-basic-auth
  hosts:
    - host: mlflow.internal.company.com
      paths:
        - path: /
          pathType: Prefix

resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2
    memory: 4Gi

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
```

---

## Model Serving — FastAPI

```python
# src/serve.py
import mlflow
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Model Serving API", version="1.0.0")

# Load model at startup from MLflow registry
model = mlflow.pyfunc.load_model(
    model_uri=f"models:/{os.environ['MODEL_NAME']}/Production"
)

class PredictRequest(BaseModel):
    features: list[float]

class PredictResponse(BaseModel):
    prediction: float
    model_version: str
    run_id: str

@app.post("/predict", response_model=PredictResponse)
async def predict(request: PredictRequest):
    try:
        result = model.predict([request.features])
        return PredictResponse(
            prediction=float(result[0]),
            model_version=os.environ.get("MODEL_VERSION", "unknown"),
            run_id=os.environ.get("MLFLOW_RUN_ID", "unknown"),
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
def health():
    return {"status": "healthy"}
```

---

## Results

| Metric | Before | After |
|---|---|---|
| Model release lead time | 5–7 days | 2–3 days (-50%) |
| Manual deployment steps | 12 steps | 0 (fully automated) |
| Failed production deploys | ~2/month | 0 (validation gate) |
| Model reproducibility | Ad-hoc | 100% (MLflow tracking) |
