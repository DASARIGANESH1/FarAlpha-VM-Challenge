# FarAlpha VM Challenge

A minimal, production-ready Flask backend with a single endpoint, deployed automatically to an Azure VM via GitHub Actions.

> **Assignment**: Build a simple backend API that exposes `GET /sayHello` returning `{"message": "Hello User."}` on **port 80**, then deploy it automatically to an Azure VM through GitHub Actions using repository secrets.

---

## Table of contents

1. [Project objective](#project-objective)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Repository layout](#repository-layout)
5. [Local setup - Windows](#local-setup---windows)
6. [Local setup - Linux / macOS](#local-setup---linux--macos)
7. [Local testing](#local-testing)
8. [Creating the private GitHub repository](#creating-the-private-github-repository)
9. [Configuring GitHub repository secrets](#configuring-github-repository-secrets)
10. [Obtaining and verifying the SSH host key](#obtaining-and-verifying-the-ssh-host-key)
11. [Initial VM provisioning](#initial-vm-provisioning)
12. [GitHub Actions workflow execution](#github-actions-workflow-execution)
13. [Automatic deployment](#automatic-deployment)
14. [Endpoint testing](#endpoint-testing)
15. [Creating the ZIP file](#creating-the-zip-file)
16. [Troubleshooting](#troubleshooting)
17. [Security considerations](#security-considerations)
18. [Submission checklist](#submission-checklist)

---

## Project objective

Deliver a small, secure, reproducible backend service that satisfies the FarAlpha assignment:

- One application route: `GET /sayHello` -> `{"message": "Hello User."}` with `Content-Type: application/json` and HTTP 200.
- Service reachable on **port 80** of the Azure VM at `http://20.127.242.99/sayHello`.
- Deployment is fully automated through GitHub Actions on every push to `main`.
- The VM is treated as a black box: it receives only a versioned artifact over SCP, never pulls code from GitHub, never stores secrets, and never executes `git pull` / `git clone`.

The codebase deliberately avoids unrelated features so that the surface area reviewed by the FarAlpha engineering team is small and easy to audit.

## Architecture

```
Developer (git push main)
        |
        v
Private GitHub repository
        |
        v
GitHub Actions runner
        |  1. checkout
        |  2. set up Python
        |  3. install deps
        |  4. pytest (fail-fast)
        |  5. package artifact (.tar.gz + .sha256)
        |  6. configure SSH from secrets (VM_SSH_KEY, VM_KNOWN_HOSTS)
        |  7. run check_prerequisites.sh over SSH (fail-fast)
        |  8. scp artifact + remote scripts to /tmp on the VM
        |  9. ssh: bash remote_deploy.sh <artifact> <sha256>
        | 10. ssh: bash smoke_test.sh <vm_host>
        | 11. cleanup ~/.ssh/vm_id on the runner
        v
Azure VM (azureuser@20.127.242.99)
        |
        |  - verify checksum
        |  - extract to /opt/faralpha/releases/<timestamp>/
        |  - create / refresh /opt/faralpha/venv (python3 -m venv)
        |  - pip install -r requirements.txt (inside venv)
        |  - copy deploy/faralpha-api.service -> /etc/systemd/system/
        |  - copy deploy/nginx.conf -> /etc/nginx/sites-available/
        |  - enable site, disable default site, nginx -t, reload
        |  - swap /opt/faralpha/current symlink (atomic)
        |  - systemctl restart faralpha-api
        |  - keep last 5 releases for rollback
        v
Nginx :80  --->  Gunicorn 127.0.0.1:8000  --->  Flask app.py
                                                        |
                                                        v
                                                  GET /sayHello
                                                        |
                                                        v
                                            {"message": "Hello User."}
```

Key invariants enforced by the design:

- **No secrets on the VM.** The SSH private key lives only in GitHub secrets and is materialised onto the runner for the duration of the job. The VM only ever has the corresponding public key in `~/.ssh/authorized_keys`.
- **No `git pull` / `git clone` on the VM.** The VM only receives a versioned tarball over SCP.
- **No source code written manually on the VM.** The `remote_deploy.sh` script that runs on the VM is itself shipped as part of the artifact - it is not hand-edited there.
- **Atomic rollback path.** Each release is unpacked into its own timestamped directory; the `current` symlink is swapped atomically. The previous release is retained for at least one deploy.
- **Idempotent deployments.** Re-running `remote_deploy.sh` against the same artifact produces the same end state.

## Prerequisites

### Local development

| Tool             | Version   | Notes                                                    |
|------------------|-----------|----------------------------------------------------------|
| Python           | 3.8+      | 3.11 recommended (matches CI).                           |
| Git              | 2.30+     | For pushing to GitHub.                                   |
| `make`           | any      | Optional - the Makefile wraps common commands.           |
| `ssh`, `scp`     | any      | Only needed for the manual `deploy.sh` wrapper.          |
| `pytest`         | 8.x       | Installed via `requirements-dev.txt`.                   |

### Target VM (provisioned by employer)

| Component        | Required for                              |
|------------------|-------------------------------------------|
| Linux            | Tested on Ubuntu 22.04 / Debian 12. Should work on RHEL-family with minor path adjustments. |
| Python 3.8+      | Application runtime.                       |
| `python3-venv`   | Creating the virtualenv.                  |
| Nginx            | Reverse proxy on port 80.                 |
| systemd          | Managing the Gunicorn service.            |
| `sudo` (initial) | One-time provisioning (installing nginx, opening the firewall). |
| TCP port 80 inbound | Publicly reachable from GitHub Actions. |

## Repository layout

```
faralpha-vm-challenge/
├── app.py                          # Flask application (single /sayHello route)
├── requirements.txt                # Runtime deps (Flask, Gunicorn)
├── requirements-dev.txt            # Dev deps (pytest, pytest-cov)
├── gunicorn.conf.py                # Gunicorn config (binds 127.0.0.1:8000)
├── Makefile                        # Common commands
├── LICENSE                         # MIT
├── .gitignore                      # Excludes secrets, caches, venvs
├── .gitattributes                  # Forces LF endings on shell scripts
├── README.md                       # This file
├── DEPLOYMENT.md                   # Deployment sequence deep-dive
├── SECURITY.md                     # Threat model & mitigations
├── tests/
│   ├── __init__.py
│   └── test_app.py                 # 8 pytest cases (status, body, content-type, 405)
├── scripts/
│   ├── check_prerequisites.sh      # Read-only VM prerequisite check
│   ├── package.sh                  # Builds .tar.gz + .sha256 locally
│   ├── deploy.sh                   # Manual deploy wrapper (uses scp + ssh)
│   ├── remote_deploy.sh            # Runs ON the VM - extract, venv, swap, restart
│   └── smoke_test.sh               # Runs ON the VM - curl localhost & public endpoint
├── deploy/
│   ├── faralpha-api.service        # systemd unit (User=azureuser, non-root)
│   └── nginx.conf                  # Nginx site (listen :80 -> 127.0.0.1:8000)
├── .github/
│   ├── workflows/
│   │   └── deploy.yml              # CI/CD pipeline (test -> build -> deploy -> smoke)
│   └── ISSUE_TEMPLATE/
│       └── bug_report.md
└── docs/
    ├── architecture.md              # Detailed architecture write-up
    ├── troubleshooting.md           # Common failures & fixes
    └── submission-checklist.md      # Maps every assignment requirement to its deliverable
```

## Local setup - Windows

These instructions assume Windows 10/11 with PowerShell. We strongly recommend using **WSL2 + Ubuntu** for the closest parity with the VM, but the project works on native Windows too.

### Option A - Native Windows (PowerShell)

```powershell
# 1. Install Python 3.11 from https://python.org (tick "Add to PATH").
# 2. Verify Python is on PATH.
python --version          # Should print 3.11.x or newer.

# 3. Unzip the project (or git clone if you have already pushed it).
Expand-Archive FarAlpha-VM-Challenge.zip -DestinationPath C:\dev\faralpha-vm-challenge
cd C:\dev\faralpha-vm-challenge

# 4. Create a virtual environment.
python -m venv .venv

# 5. Activate it.
.\.venv\Scripts\Activate.ps1
# If execution policy blocks the script, run once:
#   Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# 6. Install dependencies.
python -m pip install --upgrade pip
pip install -r requirements-dev.txt

# 7. Run tests.
pytest -v

# 8. Run the app locally (development server, port 5000).
flask --app app run --host 127.0.0.1 --port 5000

# 9. Test the endpoint from another shell.
curl http://127.0.0.1:5000/sayHello
# -> {"message":"Hello User."}
```

### Option B - WSL2 (recommended for parity with the VM)

Open a WSL2 Ubuntu shell and follow the **Linux / macOS** instructions below.

## Local setup - Linux / macOS

```bash
# 1. Verify Python 3 is available (3.8+).
python3 --version

# 2. Unzip (or clone) the project.
unzip FarAlpha-VM-Challenge.zip
cd faralpha-vm-challenge

# 3. Create a virtual environment.
python3 -m venv .venv

# 4. Activate it.
source .venv/bin/activate

# 5. Install dependencies.
pip install --upgrade pip
pip install -r requirements-dev.txt

# 6. Run tests.
pytest -v

# 7. Run Gunicorn locally (production-like, binds 127.0.0.1:8000).
gunicorn --config gunicorn.conf.py "app:application"
# In another terminal:
curl http://127.0.0.1:8000/sayHello
# -> {"message":"Hello User."}
```

Alternatively, use the provided `Makefile`:

```bash
make install-dev    # create venv + install dev deps
make test           # run pytest
make gunicorn       # run Gunicorn locally
```

## Local testing

```bash
# Activate the venv first.
source .venv/bin/activate            # Linux/macOS
.\.venv\Scripts\Activate.ps1          # Windows PowerShell

# Run the full pytest suite.
pytest -v

# Or with coverage.
pytest --cov=app --cov-report=term-missing
```

Expected output (8 tests, all passing):

```
tests/test_app.py::test_say_hello_returns_200                PASSED
tests/test_app.py::test_say_hello_returns_exact_json_body     PASSED
tests/test_app.py::test_say_hello_content_type_is_json       PASSED
tests/test_app.py::test_say_hello_body_byte_exact            PASSED
tests/test_app.py::test_say_hello_rejects_post               PASSED
tests/test_app.py::test_say_hello_rejects_put                PASSED
tests/test_app.py::test_say_hello_rejects_delete             PASSED
tests/test_app.py::test_healthz_returns_200                  PASSED
```

A failing test will produce a non-zero exit code and prevent the deployment workflow from proceeding.

## Creating the private GitHub repository

1. Sign in to https://github.com.
2. Click **New repository**.
3. Set the **Repository name** to `faralpha-vm-challenge`.
4. Choose **Private** (mandatory for this assignment).
5. Do **NOT** tick "Add a README", "Add .gitignore", or "Choose a license" - the ZIP already contains these files and they would create merge conflicts.
6. Click **Create repository**.
7. From the project root:

```bash
git init
git add .
git commit -m "Initial commit: FarAlpha VM Challenge"
git branch -M main
git remote add origin git@github.com:<your-username>/faralpha-vm-challenge.git
git push -u origin main
```

> If you have not configured an SSH key for your GitHub account, use the HTTPS remote instead:
> `git remote add origin https://github.com/<your-username>/faralpha-vm-challenge.git`

## Configuring GitHub repository secrets

Go to **Settings -> Secrets and variables -> Actions -> New repository secret** and create exactly these four secrets:

| Name              | Value                                                                                       | Notes                                                                                                          |
|-------------------|---------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| `VM_HOST`         | `20.127.242.99`                                                                             | The public IP of the Azure VM.                                                                                  |
| `VM_USER`         | `azureuser`                                                                                 | The SSH username supplied in the assignment.                                                                    |
| `VM_SSH_KEY`      | The full PEM contents of the SSH private key provided by the employer.                       | One single-line value if pasted through the GitHub UI; multi-line is fine too. **Never commit this to git.** |
| `VM_KNOWN_HOSTS`  | The output of `ssh-keyscan -H 20.127.242.99` run from your local machine.                   | Used for `StrictHostKeyChecking=yes`. See the next section for how to verify it.                                |

After saving, the secrets page should list four entries. The values are encrypted at rest by GitHub and are never exposed in workflow logs.

## Obtaining and verifying the SSH host key

The `VM_KNOWN_HOSTS` secret prevents man-in-the-middle attacks. It must contain the SSH host public key of the VM, in the same format that the OpenSSH `known_hosts` file uses.

### How to obtain it

From a machine you trust (your laptop, NOT the VM itself):

```bash
ssh-keyscan -H 20.127.242.99 > known_hosts
cat known_hosts
```

You will see one or more lines like:

```
|1|abcdef...=|ghijkl...= ssh-rsa AAAAB3NzaC1yc2E...
|1|abcdef...=|ghijkl...= ecdsa-sha2-nistp256 AAAA...
|1|abcdef...=|ghijkl...= ssh-ed25519 AAAA...
```

### How to verify it (recommended)

Do NOT blindly trust `ssh-keyscan` output - an attacker could be on the network path between you and the VM. Instead, cross-check the host key fingerprint by logging into the VM through a trusted channel and running:

```bash
# On the VM:
ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub
# Example output:
# 256 SHA256:AbCdEf... root@vm (ED25519)
```

Compare that fingerprint with the one OpenSSH reports the first time you SSH to the VM:

```bash
# On your laptop:
ssh azureuser@20.127.242.99
# OpenSSH prints:
#   The authenticity of host '20.127.242.99 (...)' can't be established.
#   ED25519 key fingerprint is SHA256:AbCdEf...
# Type `yes` only if this matches the fingerprint you obtained on the VM.
```

Once verified, paste the contents of `known_hosts` (the file you produced with `ssh-keyscan`) into the `VM_KNOWN_HOSTS` secret. If the host key ever changes (e.g. the VM is rebuilt), update this secret before the next deploy.

### Public key vs private key - the distinction

The VM's `~/.ssh/authorized_keys` file contains a **public** key. Anyone can read it; it can only be used to verify signatures, never to log in. The **private** counterpart lives only in GitHub secrets and is materialised onto the GitHub Actions runner for the duration of a deploy job. The private key never touches the VM.

## Initial VM provisioning

The first time you point this project at the VM, the OS may be missing Python 3, Nginx, or systemd. The workflow handles this gracefully:

1. The workflow's "Run prerequisite check on VM" step transfers `scripts/check_prerequisites.sh` to the VM and executes it.
2. The script is **read-only**: it does not install anything, it only reports what is present or missing.
3. If a prerequisite is missing, the workflow fails fast with a clear error message - it does NOT attempt to deploy onto an unprepared VM.
4. To prepare the VM (one-time, manually with the employer-provided SSH key):

```bash
# SSH into the VM with the key you were given:
ssh -i /path/to/employer-key.pem azureuser@20.127.242.99

# Detect the OS:
cat /etc/os-release

# Install prerequisites - Ubuntu/Debian:
sudo apt-get update
sudo apt-get install -y nginx python3 python3-venv python3-pip

# Install prerequisites - RHEL/CentOS/Rocky/Alma:
sudo dnf install -y nginx python3

# Enable nginx to start on boot:
sudo systemctl enable --now nginx

# Open the firewall (Ubuntu ufw):
sudo ufw allow 80/tcp
sudo ufw allow OpenSSH
sudo ufw --force enable

# Open the firewall (RHEL firewalld):
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload

# IMPORTANT: also open port 80 in the Azure Network Security Group
# attached to the VM. This is done in the Azure Portal or with:
#   az network nsg rule create -g <rg> --nsg-name <nsg> \
#       --name allow-http --priority 1000 \
#       --source-address-prefixes Internet \
#       --destination-port-ranges 80 --protocol Tcp \
#       --access Allow
```

After provisioning, re-run the prerequisite check from your laptop to confirm the VM is ready:

```bash
scp -i /path/to/employer-key.pem scripts/check_prerequisites.sh \
    azureuser@20.127.242.99:/tmp/check_prerequisites.sh
ssh -i /path/to/employer-key.pem azureuser@20.127.242.99 \
    "bash /tmp/check_prerequisites.sh"
```

You should see `[ OK ]` lines for every check, and an exit code of 0.

## GitHub Actions workflow execution

The workflow at `.github/workflows/deploy.yml` performs three jobs in sequence:

1. **test** - check out the source, set up Python, install dev dependencies, run pytest. Any test failure halts the pipeline.
2. **build-artifact** - invoke `scripts/package.sh` to produce `artifacts/faralpha-api-<version>.tar.gz` and `artifacts/faralpha-api-<version>.tar.gz.sha256`. Upload both as a GitHub Actions artifact for traceability.
3. **deploy** - download the artifact, verify its SHA-256, configure SSH from secrets, transfer the artifact + remote scripts to the VM, run `remote_deploy.sh`, then run `smoke_test.sh`.

The workflow has:

- `concurrency: deploy-faralpha-api` with `cancel-in-progress: false` so overlapping deploys are queued rather than racing.
- `permissions: contents: read` - the workflow cannot modify the repo.
- All third-party actions pinned to full commit SHAs.
- A `timeout-minutes` on every job to prevent stuck builds.

## Automatic deployment

Every `git push` to `main` triggers the workflow automatically. To trigger manually:

1. Open the repository on GitHub.
2. Click **Actions** in the top tab bar.
3. Select **Deploy FarAlpha API** in the left sidebar.
4. Click **Run workflow** -> **Run workflow** (default branch `main`).

Watch the workflow run. Each step prints a coloured status. If everything passes, the **Summary** at the end of the run shows the deployed endpoint URL.

## Endpoint testing

Once the deployment finishes successfully:

```bash
# From your laptop (over the public internet):
curl -i http://20.127.242.99/sayHello
```

Expected response:

```
HTTP/1.1 200 OK
Server: nginx/...
Date: ...
Content-Type: application/json
Content-Length: 27
Connection: keep-alive

{"message":"Hello User."}
```

The CI workflow runs an equivalent smoke test from the VM itself (over the loopback and the public hostname) before declaring success. A failed smoke test fails the workflow.

## Creating the ZIP file

The project ships with a packaging helper that excludes secrets and caches:

```bash
# From the project root:
bash scripts/package.sh artifacts local "$(date -u +%Y%m%d%H%M%S)"

# To build the submission ZIP (everything except secrets):
cd ..
zip -r FarAlpha-VM-Challenge.zip faralpha-vm-challenge \
    -x 'faralpha-vm-challenge/.git/*' \
    -x 'faralpha-vm-challenge/.venv/*' \
    -x 'faralpha-vm-challenge/__pycache__/*' \
    -x 'faralpha-vm-challenge/.pytest_cache/*' \
    -x 'faralpha-vm-challenge/artifacts/*' \
    -x '*.pem' -x '*.key' \
    -x 'faralpha-vm-challenge/.env' \
    -x 'faralpha-vm-challenge/.env.*'
```

The provided ZIP file (`FarAlpha-VM-Challenge.zip`) was produced with the same exclusion list and was scanned for known secret patterns before being sealed.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for the full list. The most common failures:

| Symptom                                          | Cause                                              | Fix                                                                 |
|--------------------------------------------------|----------------------------------------------------|---------------------------------------------------------------------|
| Workflow fails at "Configure SSH"                 | `VM_KNOWN_HOSTS` secret missing or empty.          | Run `ssh-keyscan -H 20.127.242.99` and paste the output as a secret. |
| Workflow fails at "Run prerequisite check on VM" | Nginx / Python 3 / systemd missing on the VM.      | Run the provisioning commands above.                               |
| Workflow fails at "Verify artifact checksum"     | Artifact upload was corrupted (rare).              | Re-run the workflow; if it persists, check the runner disk space. |
| Workflow fails at "Run smoke test"               | Service did not start, or firewall blocking 80.   | SSH in and check `systemctl status faralpha-api` and `nginx -t`.   |
| `curl http://20.127.242.99/sayHello` times out  | Azure NSG not allowing inbound TCP 80.             | Add a network security rule for port 80 in the Azure Portal.       |
| `systemctl status faralpha-api` shows crashed   | Python dependency install failed in the venv.      | Check `journalctl -u faralpha-api -n 100` for the trace.           |

## Security considerations

See [SECURITY.md](SECURITY.md) for the full threat model. Summary:

- **No secrets in the repo.** The `.gitignore` excludes `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`, `.env*`, etc. The packaging script double-checks the artifact does not contain any of these patterns.
- **No secrets on the VM.** The VM only has the public key in `~/.ssh/authorized_keys`. The private key never leaves GitHub secrets.
- **Host-key verification is on.** `StrictHostKeyChecking=yes` is used everywhere; `UserKnownHostsFile` is populated from the `VM_KNOWN_HOSTS` secret. We never set `StrictHostKeyChecking=no`.
- **Gunicorn never exposed publicly.** It binds to `127.0.0.1:8000` only. Nginx on port 80 is the sole entry point.
- **Application runs as a non-root user.** The systemd unit specifies `User=azureuser`. The unit is also hardened with `NoNewPrivileges`, `ProtectSystem=full`, etc.
- **Idempotent, atomic deployments with rollback.** The `current` symlink is swapped atomically; the previous release is retained. A failed service start rolls back automatically.

## Submission checklist

See [docs/submission-checklist.md](docs/submission-checklist.md) for the exhaustive list mapping every requirement in the assignment brief to its deliverable in this project.
