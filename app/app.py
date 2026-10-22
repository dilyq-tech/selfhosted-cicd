import os

from flask import Flask, Response, jsonify

app = Flask(__name__)


@app.route("/")
def index() -> Response:
    payload: dict[str, str] = {
        "service": os.environ.get("APP_NAME", "cicd-demo-app"),
        "status": "ok",
        "version": "1.0.0",
    }
    return jsonify(payload)


@app.route("/health")
def health() -> Response:
    return jsonify(healthy=True)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8001)
