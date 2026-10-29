#!/usr/bin/env bash
# ---------------------------------------------------------------
# FarAlpha VM Challenge - package.sh
# ---------------------------------------------------------------
# Purpose:
#   Build a versioned deployment artefact locally (on the GitHub
#   Actions runner). The artefact is a single .tar.gz file that
#   contains:
#     - app.py
#     - requirements.txt
#     - gunicorn.conf.py
#     - deploy/faralpha-api.service
#     - deploy/nginx.conf
#     - scripts/remote_deploy.sh
#     - scripts/smoke_test.sh
#
#   A SHA-256 checksum file is produced alongside, used by the
#   remote script to verify integrity after transfer.
#
# Usage:
#   bash scripts/package.sh <output_dir> <version>
#
# Outputs:
#   <output_dir>/faralpha-api-<version>.tar.gz
#   <output_dir>/faralpha-api-<version>.tar.gz.sha256
# ---------------------------------------------------------------
set -euo pipefail

OUTPUT_DIR="${1:-artifacts}"
VERSION="${2:-$(date -u '+%Y%m%d%H%M%S')}"
SHORT_GIT_SHA="${3:-nogit}"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
fi

# Resolve the project root (parent of the scripts/ directory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${PROJECT_ROOT}"

ARTIFACT_NAME="faralpha-api-${VERSION}"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

# Create a staging directory with ONLY the files needed on the VM.
mkdir -p "${STAGING_DIR}/${ARTIFACT_NAME}/deploy"
mkdir -p "${STAGING_DIR}/${ARTIFACT_NAME}/scripts"

# Copy source files (NO secrets, no .git, no venv, no caches).
cp app.py "${STAGING_DIR}/${ARTIFACT_NAME}/"
cp requirements.txt "${STAGING_DIR}/${ARTIFACT_NAME}/"
cp gunicorn.conf.py "${STAGING_DIR}/${ARTIFACT_NAME}/"

# Copy deploy configs.
cp deploy/faralpha-api.service "${STAGING_DIR}/${ARTIFACT_NAME}/deploy/"
cp deploy/nginx.conf "${STAGING_DIR}/${ARTIFACT_NAME}/deploy/"

# Copy remote scripts (these are the only scripts that should run on
# the VM - smoke_test.sh and remote_deploy.sh).
cp scripts/remote_deploy.sh "${STAGING_DIR}/${ARTIFACT_NAME}/scripts/"
cp scripts/smoke_test.sh "${STAGING_DIR}/${ARTIFACT_NAME}/scripts/"

# Write a version manifest so the VM can record exactly what was deployed.
cat > "${STAGING_DIR}/${ARTIFACT_NAME}/VERSION" <<EOF
name=FarAlpha-VM-Challenge
version=${VERSION}
git_sha=${SHORT_GIT_SHA}
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
built_on=github-actions
EOF

# Write a MANIFEST listing every file in the artifact.
{
    pushd "${STAGING_DIR}/${ARTIFACT_NAME}" >/dev/null
    find . -type f -print0 | xargs -0 sha256sum | sed 's| \./| |'
    popd >/dev/null
} > "${STAGING_DIR}/${ARTIFACT_NAME}/MANIFEST"

# Pack the tarball.
TARBALL="${OUTPUT_DIR}/${ARTIFACT_NAME}.tar.gz"
tar -czf "${TARBALL}" -C "${STAGING_DIR}" "${ARTIFACT_NAME}"

# Compute SHA-256 of the tarball itself.
SHA256_FILE="${TARBALL}.sha256"
sha256sum "${TARBALL}" | awk '{print $1}' > "${SHA256_FILE}"

# Also write the SHA256 next to the tarball name so the remote script
# can detect it transparently.
echo "Artifact:  ${TARBALL}"
echo "SHA-256:   $(cat "${SHA256_FILE}")"
echo "Version:   ${VERSION}"
echo "Size:      $(du -h "${TARBALL}" | awk '{print $1}')"

# Validate that the artifact is non-empty (sanity check).
if [[ ! -s "${TARBALL}" ]]; then
    echo "ERROR: produced artifact is empty" >&2
    exit 1
fi
