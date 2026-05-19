import os
import mlflow
import mlflow.sklearn
import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import accuracy_score, f1_score, roc_auc_score
from sklearn.model_selection import train_test_split
from mlflow.models.signature import infer_signature


def evaluate(model, X_test, y_test):
    preds = model.predict(X_test)
    proba = model.predict_proba(X_test)[:, 1]
    return {
        "accuracy": accuracy_score(y_test, preds),
        "f1_score": f1_score(y_test, preds, average="weighted"),
        "roc_auc": roc_auc_score(y_test, proba),
    }


def train(params: dict, X_train, y_train, X_test, y_test):
    mlflow.set_tracking_uri(os.environ["MLFLOW_TRACKING_URI"])
    mlflow.set_experiment(os.environ.get("MLFLOW_EXPERIMENT", "default"))

    with mlflow.start_run(tags={"environment": os.environ.get("ENV", "dev")}):
        mlflow.log_params(params)

        model = GradientBoostingClassifier(**params)
        model.fit(X_train, y_train)

        metrics = evaluate(model, X_test, y_test)
        mlflow.log_metrics(metrics)

        signature = infer_signature(X_train, model.predict(X_train))
        mlflow.sklearn.log_model(
            model,
            artifact_path="model",
            signature=signature,
            registered_model_name=os.environ["MODEL_NAME"],
        )

        threshold = float(os.environ.get("ACCURACY_THRESHOLD", "0.85"))
        if metrics["accuracy"] < threshold:
            raise ValueError(
                f"Accuracy {metrics['accuracy']:.4f} below threshold {threshold}"
            )

        print(f"Run ID: {mlflow.active_run().info.run_id}")
        print(f"Metrics: {metrics}")
        return mlflow.active_run().info.run_id


if __name__ == "__main__":
    # Example: synthetic data for local testing
    from sklearn.datasets import make_classification
    X, y = make_classification(n_samples=5000, n_features=20, random_state=42)
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

    params = {
        "n_estimators": int(os.environ.get("N_ESTIMATORS", 100)),
        "max_depth": int(os.environ.get("MAX_DEPTH", 5)),
        "learning_rate": float(os.environ.get("LEARNING_RATE", 0.1)),
    }
    train(params, X_train, y_train, X_test, y_test)
