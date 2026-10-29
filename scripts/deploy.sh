#!/usr/bin/env bash
# ---------------------------------------------------------------
# FarAlpha VM Challenge - deploy.sh
# ---------------------------------------------------------------
# Purpose:
#   Convenience wrapper that performs a LOCAL deployment (used for
#   testing on a developer machine OR for one-off manual deployment
#   to a VM you have direct SSH access to).
#
#   The CI/CD pipeline does NOT use this script - it uses the GitHub
#   Actions workflow at .github/workflows/deploy.yml which performs
#   the same steps but driven by GitHub Actions.
#
# Usage:
#   bash scripts/deploy.sh <vm_host> <vm_user> [ssh_key_path]
#
# Example:
#   bash scripts/deploy.sh 20.127.242.99 azureuser ~/.ssh/id_ed25519
# ---------------------------------------------------------------
set -euo pipefail

VM_HOST="${1:-}"
VM_USER="${2:-azureuser}"
SSH_KEY_PATH="${3:-${HOME}/.ssh/id_ed25519}"

if [[ -z "${VM_HOST}" ]]; then
    echo "Usage: $0 <vm_host> <vm_user> [ssh_key_path]" >&2
    exit 1
fi

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    echo "ERROR: SSH key not found at ${SSH_KEY_PATH}" >&2
    echo "Provide a path to a private key file." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Build the artifact.
VERSION="$(date -u '+%Y%m%d%H%M%S')"
ARTIFACT_DIR="${PROJECT_ROOT}/artifacts"
bash "${SCRIPT_DIR}/package.sh" "${ARTIFACT_DIR}" "${VERSION}" "local"

ARTIFACT_PATH="${ARTIFACT_DIR}/faralpha-api-${VERSION}.tar.gz"
EXPECTED_SHA256="$(cat "${ARTIFACT_PATH}.sha256")"

if [[ -z "${EXPECTED_SHA256}" ]]; then
    echo "ERROR: missing checksum for ${ARTIFACT_PATH}" >&2
    exit 1
fi

echo "[deploy] Transferring artifact to ${VM_USER}@${VM_HOST}..."
REMOTE_PATH="/tmp/$(basename "${ARTIFACT_PATH}")"
scp -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=accept-new \
    "${ARTIFACT_PATH}" "${VM_USER}@${VM_HOST}:${REMOTE_PATH}"

echo "[deploy] Running remote_deploy.sh on the VM..."
ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=accept-new \
    "${VM_USER}@${VM_HOST}" \
    "bash /tmp/remote_deploy.sh ${REMOTE_PATH} ${EXPECTED_SHA256}"

echo "[deploy] Running smoke_test.sh on the VM..."
ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=accept-new \
    "${VM_USER}@${VM_HOST}" \
    "bash /tmp/smoke_test.sh ${VM_HOST}"

echo "[deploy] Done."
