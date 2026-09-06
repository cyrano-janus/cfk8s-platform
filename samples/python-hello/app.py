import os
from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def index():
    return jsonify(
        message="Hallo von Python auf Korifi",
        buildpack="paketo-buildpacks/python",
        vcap_services_present=bool(os.getenv("VCAP_SERVICES")),
    )


@app.get("/env")
def env():
    # Nützlich für die Broker-Verifikation: zeigt, was in VCAP_SERVICES landet.
    return jsonify(vcap_services=os.getenv("VCAP_SERVICES", "<leer>"))
