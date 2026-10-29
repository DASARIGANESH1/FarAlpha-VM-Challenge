"""
FarAlpha VM Challenge - Application unit tests.

Run with:  pytest -v

These tests use the Flask test client (no network is involved). They
validate the exact contract required by the assignment:

    GET /sayHello -> 200
    {"message": "Hello User."}
    Content-Type: application/json

Plus the inverse: a disallowed HTTP method on /sayHello must be
rejected with an appropriate 4xx status code.
"""

from __future__ import annotations

import json

import pytest

from app import create_app


@pytest.fixture()
def client():
    """Provide a fresh Flask test client per test."""
    app = create_app()
    app.config.update(TESTING=True)
    return app.test_client()


def test_say_hello_returns_200(client):
    """GET /sayHello must respond with HTTP 200."""
    response = client.get("/sayHello")
    assert response.status_code == 200, (
        f"expected 200, got {response.status_code}: {response.data!r}"
    )


def test_say_hello_returns_exact_json_body(client):
    """Response body must be exactly {"message": "Hello User."}."""
    response = client.get("/sayHello")
    parsed = response.get_json()
    assert parsed == {"message": "Hello User."}, (
        f"unexpected body: {parsed!r}"
    )


def test_say_hello_content_type_is_json(client):
    """Content-Type must be application/json."""
    response = client.get("/sayHello")
    content_type = response.headers.get("Content-Type", "")
    assert content_type.startswith("application/json"), (
        f"expected application/json, got {content_type!r}"
    )


def test_say_hello_body_byte_exact(client):
    """Byte-for-byte check of the response body.

    The assignment specifies the exact JSON response. We verify the
    serialised body matches Flask's default compact JSON output for
    the expected payload.
    """
    response = client.get("/sayHello")
    expected_bytes = json.dumps({"message": "Hello User."}).encode("utf-8")
    # Flask's default JSON encoder may use compact separators. Compare
    # the parsed object first (above) and the bytes here.
    assert response.data == b'{"message":"Hello User."}\n' or \
        response.data == expected_bytes or \
        response.data == expected_bytes.replace(b'",', b'", ').replace(b'{', b'{ ').replace(b'}', b' }'), (
        f"unexpected raw body: {response.data!r}"
    )


def test_say_hello_rejects_post(client):
    """POST to /sayHello must be rejected (405 Method Not Allowed)."""
    response = client.post("/sayHello")
    assert response.status_code == 405, (
        f"expected 405, got {response.status_code}"
    )


def test_say_hello_rejects_put(client):
    """PUT to /sayHello must be rejected (405 Method Not Allowed)."""
    response = client.put("/sayHello")
    assert response.status_code == 405, (
        f"expected 405, got {response.status_code}"
    )


def test_say_hello_rejects_delete(client):
    """DELETE to /sayHello must be rejected (405 Method Not Allowed)."""
    response = client.delete("/sayHello")
    assert response.status_code == 405, (
        f"expected 405, got {response.status_code}"
    )


def test_healthz_returns_200(client):
    """The /healthz endpoint used by the smoke test must return 200."""
    response = client.get("/healthz")
    assert response.status_code == 200, (
        f"expected 200, got {response.status_code}"
    )
