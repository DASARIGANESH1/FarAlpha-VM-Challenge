#!/usr/bin/env bash
# ---------------------------------------------------------------
# FarAlpha VM Challenge - smoke_test.sh
# ---------------------------------------------------------------
# Purpose:
#   Verify the deployed endpoint works end-to-end over HTTP.
#   This script is invoked REMOTELY on the VM (via SSH) after the
#   remote_deploy.sh script has finished.
#
#   It checks BOTH:
#     - The local Gunicorn socket (127.0.0.1:8000) directly.
#     - The public Nginx endpoint (port 80) - this is the actual
#       contract required by the assignment.
#
# Usage:
#   bash smoke_test.sh [public_host]
#
#   public_host defaults to localhost (which exercises nginx through
#   the loopback interface). When run from GitHub Actions, pass the
#   public IP / hostname as $1 so the smoke test validates the
#   publicly reachable URL.
#
# Exit codes:
#   0 - all checks passed
#   1 - one or more checks failed
# ---------------------------------------------------------------
set -euo pipefail

TARGET="${1:-localhost}"
ENDPOINT_PATH="/sayHello"
LOCAL_URL="http://127.0.0.1:8000${ENDPOINT_PATH}"
PUBLIC_URL="http://${TARGET}${ENDPOINT_PATH}"
HEALTH_LOCAL_URL="http://127.0.0.1:8000/healthz"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

ok()   { printf "%s[ OK ]%s %s\n" "${GREEN}" "${NC}" "$*"; }
fail() { printf "%s[FAIL]%s %s\n" "${RED}" "${NC}" "$*"; }
info() { printf "%s[INFO ]%s %s\n" "${BLUE}" "${NC}" "$*"; }

ERRORS=0

info "FarAlpha VM Challenge - smoke test"
info "Local endpoint:  ${LOCAL_URL}"
info "Public endpoint: ${PUBLIC_URL}"
echo ""

# Use curl with sensible timeouts. --fail makes curl exit non-zero on
# 4xx / 5xx HTTP status. We capture the body separately to inspect it.
check_url() {
    local label="$1"
    local url="$2"
    local expected_status="$3"
    local expected_body="$4"

    info "Checking ${label}: ${url}"
    local code body
    if ! code=$(curl -s -o /tmp/faralpha_smoke_body \
        --max-time 15 --connect-timeout 10 \
        -w '%{http_code}' "${url}" 2>/dev/null); then
        fail "Request failed (curl error) for ${url}"
        ERRORS=$((ERRORS+1))
        return
    fi
    body=$(cat /tmp/faralpha_smoke_body 2>/dev/null || true)

    if [[ "${code}" != "${expected_status}" ]]; then
        fail "Status ${code}, expected ${expected_status}"
        ERRORS=$((ERRORS+1))
        return
    fi

    # Body check is a "contains" rather than exact equality because
    # Flask's jsonify output is deterministic but we want a tolerant
    # match that also passes when the body contains the key payload.
    if [[ -n "${expected_body}" ]] && ! echo "${body}" | grep -q "${expected_body}"; then
        fail "Body mismatch."
        fail "  expected to contain: ${expected_body}"
        fail "  got: ${body}"
        ERRORS=$((ERRORS+1))
        return
    fi

    ok "HTTP ${code} - body contains '${expected_body}'"
}

# 1. Health check on local Gunicorn socket.
check_url "health (local Gunicorn)" "${HEALTH_LOCAL_URL}" "200" "ok"

# 2. /sayHello on local Gunicorn socket (bypass nginx - sanity check).
check_url "/sayHello (local Gunicorn)" "${LOCAL_URL}" "200" "Hello User."

# 3. /sayHello through Nginx (the actual contract).
check_url "/sayHello (through Nginx)" "${PUBLIC_URL}" "200" "Hello User."

# 4. Content-Type check on the public endpoint.
info "Checking Content-Type on ${PUBLIC_URL}"
ct=$(curl -sI --max-time 15 --connect-timeout 10 "${PUBLIC_URL}" 2>/dev/null \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}')
if [[ "${ct}" == application/json* ]]; then
    ok "Content-Type is application/json (${ct})"
else
    fail "Content-Type '${ct}' is not application/json"
    ERRORS=$((ERRORS+1))
fi
echo ""

if [[ "${ERRORS}" -gt 0 ]]; then
    fail "${ERRORS} smoke test check(s) failed."
    exit 1
fi

ok "All smoke test checks passed."
exit 0
