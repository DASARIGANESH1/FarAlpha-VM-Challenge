#!/usr/bin/env bash
# ---------------------------------------------------------------
# FarAlpha VM Challenge - remote_deploy.sh
# ---------------------------------------------------------------
# Purpose:
#   Run ON THE VM (via SSH from GitHub Actions, NOT git pull) to:
#     1. Verify the artefact's checksum.
#     2. Extract the artefact into a versioned release directory.
#     3. Create / refresh a Python virtualenv.
#     4. Install Python dependencies into the venv.
#     5. Atomically swap the current symlink to the new release.
#     6. Install / update the systemd unit and nginx config.
#     7. Reload systemd and restart services.
#     8. Keep the previous release for rollback.
#
# IMPORTANT:
#   - This script is transferred AS PART of the deployment artefact.
#   - It NEVER pulls code from GitHub.
#   - It NEVER reads any secrets from the VM environment.
#   - It does NOT require sudo for the application files - only for
#     installing the systemd unit and the nginx site config.
#
# Usage (invoked remotely by the GitHub Actions workflow):
#   bash remote_deploy.sh <artifact_path> <expected_sha256>
#
# Exit codes:
#   0 - deployment succeeded
#   1 - integrity check failed, extraction failed, or service restart failed
#   2 - prerequisite check failed (do not attempt to deploy)
# ---------------------------------------------------------------
set -euo pipefail

ARTIFACT_PATH="${1:-}"
EXPECTED_SHA256="${2:-}"

# Configurable paths.
DEPLOY_ROOT="/opt/faralpha"
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_LINK="${DEPLOY_ROOT}/current"
VENV_DIR="${DEPLOY_ROOT}/venv"
STAGING_DIR="${DEPLOY_ROOT}/staging"
SERVICE_NAME="faralpha-api"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
NGINX_SITE_FILE="/etc/nginx/sites-available/${SERVICE_NAME}.conf"
NGINX_ENABLED_LINK="/etc/nginx/sites-enabled/${SERVICE_NAME}.conf"
NGINX_DEFAULT_LINK="/etc/nginx/sites-enabled/default"
RUN_USER="${SUDO_USER:-$(whoami)}"
RUN_USER="${RUN_USER#*)}"  # strip any prefix from sudo
RUN_USER="$(whoami)"  # reliable - we are NOT running under sudo

log()   { printf "[deploy] %s\n" "$*"; }
err()   { printf "[deploy][ERROR] %s\n" "$*" >&2; }

# ---------------------------------------------------------------
# 0. Argument validation
# ---------------------------------------------------------------
if [[ -z "${ARTIFACT_PATH}" ]] || [[ -z "${EXPECTED_SHA256}" ]]; then
    err "Usage: remote_deploy.sh <artifact_path> <expected_sha256>"
    exit 1
fi

if [[ ! -f "${ARTIFACT_PATH}" ]]; then
    err "Artifact file not found: ${ARTIFACT_PATH}"
    exit 1
fi

# ---------------------------------------------------------------
# 1. Verify checksum (reject tampered / incomplete transfers)
# ---------------------------------------------------------------
log "Verifying artifact checksum..."
ACTUAL_SHA256=$(sha256sum "${ARTIFACT_PATH}" | awk '{print $1}')
if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
    err "Checksum mismatch!"
    err "  expected: ${EXPECTED_SHA256}"
    err "  actual:   ${ACTUAL_SHA256}"
    err "Refusing to deploy - artifact may be corrupted or tampered with."
    exit 1
fi
log "Checksum OK (${ACTUAL_SHA256:0:12}...)"

# ---------------------------------------------------------------
# 2. Detect sudo availability (needed for systemd + nginx only)
# ---------------------------------------------------------------
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
    else
        err "This user is not root and has no passwordless sudo."
        err "Without sudo, the systemd unit and nginx config cannot be installed."
        err "Run initial provisioning first (see check_prerequisites.sh)."
        exit 2
    fi
fi

# ---------------------------------------------------------------
# 3. Prepare directories
# ---------------------------------------------------------------
log "Preparing release directories under ${DEPLOY_ROOT}..."
${SUDO} mkdir -p "${RELEASES_DIR}" "${STAGING_DIR}"
${SUDO} chown -R "$(id -u):$(id -g)" "${DEPLOY_ROOT}"

# ---------------------------------------------------------------
# 4. Extract the artefact to a staging directory
# ---------------------------------------------------------------
TIMESTAMP=$(date -u '+%Y%m%d%H%M%S')
RELEASE_DIR="${RELEASES_DIR}/${TIMESTAMP}"

log "Extracting artifact to staging area..."
rm -rf "${STAGING_DIR:?}"/*
tar -xzf "${ARTIFACT_PATH}" -C "${STAGING_DIR}"

# The tarball contains a single top-level directory. Move it into place.
TOP_DIR=$(find "${STAGING_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n1)
if [[ -z "${TOP_DIR}" ]]; then
    err "Artifact is empty or has unexpected layout."
    exit 1
fi

log "Moving release into ${RELEASE_DIR}..."
mkdir -p "${RELEASE_DIR}"
cp -a "${TOP_DIR}/." "${RELEASE_DIR}/"

# Capture the version manifest for logging.
if [[ -f "${RELEASE_DIR}/VERSION" ]]; then
    log "Deploying release:"
    sed 's/^/          /' "${RELEASE_DIR}/VERSION"
fi

# ---------------------------------------------------------------
# 5. Create / refresh the virtualenv and install dependencies
# ---------------------------------------------------------------
log "Ensuring virtualenv at ${VENV_DIR}..."
if [[ ! -d "${VENV_DIR}" ]]; then
    python3 -m venv "${VENV_DIR}"
fi
# Upgrade pip for reliable dependency resolution.
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip >/dev/null

log "Installing Python dependencies..."
"${VENV_DIR}/bin/pip" install --quiet -r "${RELEASE_DIR}/requirements.txt"

# Sanity check: ensure gunicorn is importable.
if ! "${VENV_DIR}/bin/python" -c 'import gunicorn, flask' >/dev/null 2>&1; then
    err "Virtualenv is missing gunicorn or flask after install."
    err "Inspect requirements.txt and retry."
    exit 1
fi
log "Virtualenv ready."

# ---------------------------------------------------------------
# 6. Install the systemd unit
# ---------------------------------------------------------------
log "Installing systemd unit -> ${SERVICE_FILE}..."
${SUDO} cp "${RELEASE_DIR}/deploy/faralpha-api.service" "${SERVICE_FILE}"
${SUDO} chmod 644 "${SERVICE_FILE}"
${SUDO} chown root:root "${SERVICE_FILE}"

# Reload systemd so it picks up the new / updated unit.
${SUDO} systemctl daemon-reload

# ---------------------------------------------------------------
# 7. Install the nginx site config
# ---------------------------------------------------------------
log "Installing nginx site config -> ${NGINX_SITE_FILE}..."
${SUDO} mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
${SUDO} cp "${RELEASE_DIR}/deploy/nginx.conf" "${NGINX_SITE_FILE}"
${SUDO} chmod 644 "${NGINX_SITE_FILE}"

# Enable the site (symlink into sites-enabled).
if [[ ! -L "${NGINX_ENABLED_LINK}" ]]; then
    ${SUDO} ln -s "${NGINX_SITE_FILE}" "${NGINX_ENABLED_LINK}"
fi

# Disable the nginx default site if it exists (frees port 80).
if [[ -L "${NGINX_DEFAULT_LINK}" ]]; then
    log "Disabling nginx default site to free port 80..."
    ${SUDO} rm -f "${NGINX_DEFAULT_LINK}"
fi

# Validate nginx config BEFORE reload - refuse to reload broken config.
if ! ${SUDO} nginx -t; then
    err "nginx -t reported a syntax error - refusing to reload."
    err "Leaving the previous deployment running."
    # Restore previous service file if possible (best-effort).
    if [[ -L "${CURRENT_LINK}" ]] && [[ -d "${CURRENT_LINK}" ]]; then
        PREV_SERVICE_FILE="${CURRENT_LINK}/deploy/faralpha-api.service"
        if [[ -f "${PREV_SERVICE_FILE}" ]]; then
            ${SUDO} cp "${PREV_SERVICE_FILE}" "${SERVICE_FILE}"
            ${SUDO} systemctl daemon-reload
        fi
    fi
    exit 1
fi

log "Reloading nginx..."
${SUDO} systemctl reload nginx || ${SUDO} systemctl restart nginx

# ---------------------------------------------------------------
# 8. Atomically swap the 'current' symlink to the new release
# ---------------------------------------------------------------
log "Swapping current symlink to new release..."
if [[ -L "${CURRENT_LINK}" ]] || [[ -e "${CURRENT_LINK}" ]]; then
    PREV_RELEASE=$(readlink -f "${CURRENT_LINK}" 2>/dev/null || true)
fi
ln -sfn "${RELEASE_DIR}" "${CURRENT_LINK}.new"
${SUDO} mv -Tf "${CURRENT_LINK}.new" "${CURRENT_LINK}"

# ---------------------------------------------------------------
# 9. Restart the application service
# ---------------------------------------------------------------
log "Restarting ${SERVICE_NAME}..."
${SUDO} systemctl restart "${SERVICE_NAME}"

# Wait briefly for the service to come up.
for i in 1 2 3 4 5; do
    if ${SUDO} systemctl is-active --quiet "${SERVICE_NAME}"; then
        log "Service is active."
        break
    fi
    sleep 1
    if [[ "${i}" -eq 5 ]]; then
        err "Service failed to start within 5s."
        err "Journal tail:"
        ${SUDO} journalctl -u "${SERVICE_NAME}" --no-pager -n 30 || true
        err "Rolling back to previous release if available..."
        if [[ -n "${PREV_RELEASE:-}" ]] && [[ -d "${PREV_RELEASE}" ]]; then
            ${SUDO} cp "${PREV_RELEASE}/deploy/faralpha-api.service" "${SERVICE_FILE}"
            ${SUDO} systemctl daemon-reload
            ln -sfn "${PREV_RELEASE}" "${CURRENT_LINK}.new"
            ${SUDO} mv -Tf "${CURRENT_LINK}.new" "${CURRENT_LINK}"
            ${SUDO} systemctl restart "${SERVICE_NAME}"
        fi
        exit 1
    fi
done

# ---------------------------------------------------------------
# 10. Cleanup old releases (keep last 5 for rollback)
# ---------------------------------------------------------------
log "Cleaning up old releases (keeping last 5)..."
cd "${RELEASES_DIR}"
ls -1dt */ 2>/dev/null | tail -n +6 | while read -r old; do
    # Do not delete the currently-linked release under any circumstances.
    if [[ "$(readlink -f "${CURRENT_LINK}")" != "$(readlink -f "${RELEASES_DIR}/${old}")" ]]; then
        rm -rf "${RELEASES_DIR:?}/${old%/}"
    fi
done

# ---------------------------------------------------------------
# 11. Done. Smoke test is invoked separately by the workflow.
# ---------------------------------------------------------------
log "Deployment complete."
log "Active release: $(readlink -f "${CURRENT_LINK}")"
exit 0
