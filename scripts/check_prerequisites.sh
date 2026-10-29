#!/usr/bin/env bash
# ---------------------------------------------------------------
# FarAlpha VM Challenge - check_prerequisites.sh
# ---------------------------------------------------------------
# Purpose:
#   Verify that the target VM has all the OS-level prerequisites
#   required for the application to be deployed.
#
# This script is INTENTIONALLY read-only. It performs NO installation
# and NO modification to the system. It only reports the current state.
#
# It is run REMOTELY by the GitHub Actions workflow (via SSH) BEFORE
# the artifact is transferred, so that a missing prerequisite fails
# the build early with a clear error message rather than half-deploying.
#
# Usage (run on the VM):
#   bash check_prerequisites.sh
#
# Exit codes:
#   0  - all prerequisites satisfied
#   1  - one or more prerequisites missing or insufficient
#   2  - unable to determine the OS (unsupported distribution)
#
# The script is safe to run multiple times (idempotent, no side effects).
# ---------------------------------------------------------------
set -euo pipefail

# Pretty colours for terminal output.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

ok()   { printf "%s[ OK ]%s %s\n" "${GREEN}" "${NC}" "$*"; }
warn() { printf "%s[WARN ]%s %s\n" "${YELLOW}" "${NC}" "$*"; }
fail() { printf "%s[FAIL]%s %s\n" "${RED}" "${NC}" "$*"; }
info() { printf "%s[INFO ]%s %s\n" "${BLUE}" "${NC}" "$*"; }

ERRORS=0

info "FarAlpha VM Challenge - prerequisite check"
info "Running as: $(whoami)@$(hostname)"
info "Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo ""

# ---------------------------------------------------------------
# 1. Detect the Linux distribution
# ---------------------------------------------------------------
info "Step 1/8 - Detecting Linux distribution"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "Distribution: ${PRETTY_NAME:-unknown} (ID=${ID:-unknown}, VERSION_ID=${VERSION_ID:-unknown})"
    OS_ID="${ID:-unknown}"
else
    fail "Could not detect OS: /etc/os-release is missing"
    fail "This VM is using an unsupported or extremely old distribution."
    exit 2
fi

case "${OS_ID}" in
    ubuntu|debian)
        info "Supported family: Debian / Ubuntu"
        ;;
    centos|rhel|rocky|almalinux|fedora|amzn)
        info "Supported family: RedHat / RPM-based"
        ;;
    *)
        warn "Unrecognised distribution: ${OS_ID}"
        warn "Deployment scripts have been tested on Ubuntu/Debian and RHEL-family."
        warn "Proceed at your own risk; some package names may differ."
        ;;
esac
echo ""

# ---------------------------------------------------------------
# 2. Check Python 3
# ---------------------------------------------------------------
info "Step 2/8 - Checking for Python 3"
if command -v python3 >/dev/null 2>&1; then
    PY_VERSION=$(python3 -c 'import sys; print("{}.{}".format(*sys.version_info[:2]))' 2>/dev/null || echo "0.0")
    PY_MAJOR=$(python3 -c 'import sys; print(sys.version_info[0])' 2>/dev/null || echo 0)
    if [[ "${PY_MAJOR}" -ge 3 ]] && [[ "$(python3 -c 'import sys; print(sys.version_info[1])')" -ge 8 ]]; then
        ok "Python ${PY_VERSION} found at $(command -v python3)"
    else
        fail "Python 3.8+ required, found ${PY_VERSION}"
        ERRORS=$((ERRORS+1))
    fi
else
    fail "python3 not found"
    fail "Install with:  sudo apt-get install -y python3 python3-venv python3-pip"
    fail "           or:  sudo dnf install -y python3"
    ERRORS=$((ERRORS+1))
fi

# Check venv module (sometimes shipped separately)
if ! python3 -c 'import venv' >/dev/null 2>&1; then
    fail "python3-venv module is missing"
    fail "Install with:  sudo apt-get install -y python3-venv"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ---------------------------------------------------------------
# 3. Check Nginx
# ---------------------------------------------------------------
info "Step 3/8 - Checking for Nginx"
if command -v nginx >/dev/null 2>&1; then
    NGINX_VERSION=$(nginx -v 2>&1 | sed 's#^[^/]*/##')
    ok "Nginx ${NGINX_VERSION} found at $(command -v nginx)"
else
    fail "nginx not found"
    fail "Install with:  sudo apt-get install -y nginx"
    fail "           or:  sudo dnf install -y nginx"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ---------------------------------------------------------------
# 4. Check systemd
# ---------------------------------------------------------------
info "Step 4/8 - Checking for systemd"
if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    ok "systemd available (systemctl at $(command -v systemctl))"
else
    fail "systemd is required to manage the application service"
    fail "This is unusual on modern Linux. Contact the VM administrator."
    ERRORS=$((ERRORS+1))
fi
echo ""

# ---------------------------------------------------------------
# 5. Check sudo privileges (informational - we don't require them
#    for routine deployments, but provisioning may need them).
# ---------------------------------------------------------------
info "Step 5/8 - Checking sudo privileges"
if sudo -n true 2>/dev/null; then
    ok "Passwordless sudo is available (used only for initial provisioning)"
elif sudo -v 2>/dev/null; then
    warn "Sudo requires a password (will prompt during provisioning only)"
else
    warn "Sudo is NOT available for this user"
    warn "Provisioning steps that need root (installing nginx, opening ports)"
    warn "must be performed by the VM administrator."
    warn "Routine application deployments do NOT require sudo."
fi
echo ""

# ---------------------------------------------------------------
# 6. Check whether ports 80 and 8000 are already in use
# ---------------------------------------------------------------
info "Step 6/8 - Checking ports 80 and 8000"

check_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        # Preferred - modern Linux.
        if ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}"; then
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | grep -q ":${port} "; then
            return 0
        fi
    else
        warn "Neither 'ss' nor 'netstat' available - cannot verify port ${port}"
        return 255
    fi
    return 1
}

if check_port 80; then
    warn "Port 80 is already in use:"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp "sport = :80" 2>/dev/null || true
    fi
    warn "The deployment script will refuse to overwrite an unrelated service."
    warn "Resolve this conflict BEFORE deploying (stop the conflicting service"
    warn "or change the listen port in deploy/nginx.conf)."
else
    ok "Port 80 is free"
fi

if check_port 8000; then
    warn "Port 8000 (Gunicorn) is already in use:"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp "sport = :8000" 2>/dev/null || true
    fi
    warn "The deployment script will stop the existing faralpha-api service"
    warn "first; if a different process is bound, it will be left alone."
else
    ok "Port 8000 is free"
fi
echo ""

# ---------------------------------------------------------------
# 7. Required system directories
# ---------------------------------------------------------------
info "Step 7/8 - Checking required directories"
for dir in /opt /etc/systemd/system /var/log; do
    if [[ -d "${dir}" ]]; then
        ok "Directory exists: ${dir}"
    else
        fail "Required directory missing: ${dir}"
        ERRORS=$((ERRORS+1))
    fi
done
echo ""

# ---------------------------------------------------------------
# 8. Disk space sanity (artefact extraction + venv)
# ---------------------------------------------------------------
info "Step 8/8 - Checking free disk space"
if command -v df >/dev/null 2>&1; then
    AVAILABLE_KB=$(df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ "${AVAILABLE_KB}" =~ ^[0-9]+$ ]]; then
        AVAILABLE_MB=$((AVAILABLE_KB / 1024))
        if [[ "${AVAILABLE_MB}" -ge 256 ]]; then
            ok "Free disk space on /opt: ${AVAILABLE_MB} MB"
        else
            warn "Low free disk space on /opt: ${AVAILABLE_MB} MB (>=256 MB recommended)"
        fi
    else
        warn "Could not parse df output"
    fi
else
    warn "df not available - skipping disk space check"
fi
echo ""

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo "------------------------------------------------"
if [[ "${ERRORS}" -eq 0 ]]; then
    ok "All required prerequisites are satisfied."
    exit 0
else
    fail "${ERRORS} prerequisite check(s) failed."
    fail "Resolve the items above and re-run this script."
    echo ""
    info "Suggested provisioning commands for Ubuntu/Debian:"
    echo "    sudo apt-get update"
    echo "    sudo apt-get install -y nginx python3 python3-venv python3-pip"
    echo "    sudo systemctl enable --now nginx"
    exit 1
fi
