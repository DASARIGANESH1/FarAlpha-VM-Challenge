"""
FarAlpha VM Challenge - Flask Backend Application

A minimal, production-ready Flask application that exposes a single
endpoint `GET /sayHello` returning the JSON payload:

    {"message": "Hello User."}

The application is designed to be served by Gunicorn (bound to
127.0.0.1:8000) behind an Nginx reverse proxy (port 80). It deliberately
avoids adding features that are not required by the assignment so that
the surface area for review is small and easy to audit.

A lightweight `/healthz` endpoint is included so that the deployment
smoke test can distinguish "the service is up" from "the service is
deploying" without coupling to the application route required by the
assignment. `/healthz` does NOT replace `/sayHello` and is intentionally
named differently to avoid any ambiguity.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Dict, Tuple

from flask import Flask, jsonify

# ---------------------------------------------------------------------------
# Application factory
# ---------------------------------------------------------------------------


def create_app() -> Flask:
    """Create and configure the Flask application instance.

    Centralising application construction inside a factory function makes
    the app trivially testable (pytest can construct a fresh app per
    test) and allows Gunicorn to import a single well-known object.
    """
    app = Flask(__name__)

    # Configuration is intentionally minimal. Sensible defaults keep the
    # application secure without requiring environment variables to be set.
    app.config.update(
        # Never return a pretty-printed JSON response by default - this
        # keeps payloads compact and matches the exact contract.
        JSONIFY_PRETTYPRINT_REGULAR=False,
        # Disable the flask debug toolbar / debug mode in production.
        DEBUG=False,
        # Hardening: send a strict-ish set of headers.
        PROPAGATE_EXCEPTIONS=False,
    )

    # Structured logging to stdout (systemd / journald captures it).
    log_level = os.environ.get("APP_LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=getattr(logging, log_level, logging.INFO),
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )

    # ---------------------------------------------------------------------
    # Routes
    # ---------------------------------------------------------------------

    @app.get("/sayHello")
    def say_hello() -> Tuple[Any, int, Dict[str, str]]:
        """Return the exact JSON payload required by the assignment.

        Returns a tuple of ``(jsonify_response, status_code, headers)``
        so that we can be explicit about both the HTTP status and the
        ``Content-Type`` header.
        """
        response = jsonify({"message": "Hello User."})
        response.status_code = 200
        return response

    @app.get("/healthz")
    def healthz():
          return jsonify({"status": "ok"}), 200
    @app.errorhandler(404)
    def not_found(_error: Any) -> Tuple[Any, int, Dict[str, str]]:
        response = jsonify({"error": "not_found"})
        response.status_code = 404
        return response

    @app.errorhandler(405)
    def method_not_allowed(_error: Any) -> Tuple[Any, int, Dict[str, str]]:
        response = jsonify({"error": "method_not_allowed"})
        response.status_code = 405
        return response

    @app.errorhandler(500)
    def internal_error(_error: Any) -> Tuple[Any, int, Dict[str, str]]:
        response = jsonify({"error": "internal_server_error"})
        response.status_code = 500
        return response

    return app


# Gunicorn loads the variable named `application` by default.
application = create_app()


if __name__ == "__main__":
    # This block is only used for local development. Production must run
    # Gunicorn bound to 127.0.0.1:8000 behind Nginx.
    port = int(os.environ.get("FLASK_RUN_PORT", "5000"))
    application.run(host="127.0.0.1", port=port)
