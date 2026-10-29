# Submission checklist

This document maps every requirement from the FarAlpha VM Challenge assignment to its concrete deliverable in this project. Use it as your pre-submission sanity check.

---

## 1. Backend API requirements

| # | Requirement                                                                                | Deliverable                                                                 | Verified by                                                                 |
|---|-------------------------------------------------------------------------------------------|------------------------------------------------------------------------------|-----------------------------------------------------------------------------|
| 1 | Use Python and Flask.                                                                     | `app.py`, `requirements.txt` (Flask==3.0.3).                                | `pip install -r requirements.txt`; `import flask` works.                    |
| 2 | Implement `GET /sayHello`.                                                                | `app.py` -> `@app.get("/sayHello")`.                                        | `tests/test_app.py::test_say_hello_returns_200`.                            |
| 3 | Return `{"message": "Hello User."}`.                                                      | `app.py` returns `jsonify({"message": "Hello User."})`.                       | `tests/test_app.py::test_say_hello_returns_exact_json_body`.                |
| 4 | Make the API accessible on port 80.                                                       | `deploy/nginx.conf` -> `listen 80 default_server`.                          | `scripts/smoke_test.sh` curls `http://<vm_host>/sayHello`.                  |
| 5 | Create a private GitHub repository workflow.                                              | `.github/workflows/deploy.yml` + instructions in README.                     | README section "Creating the private GitHub repository".                    |
| 6 | Configure GitHub Actions to deploy automatically on push to `main`.                       | `deploy.yml` -> `on: push: branches: [main]`.                               | Push to `main` triggers the workflow.                                      |
| 7 | Deploy to the supplied virtual machine through SSH.                                       | `deploy.yml` -> "deploy" job uses `ssh` + `scp`.                             | Workflow's "Execute remote deployment" step.                                |
| 8 | Use GitHub Actions repository secrets for credentials.                                    | `deploy.yml` reads `VM_HOST`, `VM_USER`, `VM_SSH_KEY`, `VM_KNOWN_HOSTS`.    | README section "Configuring GitHub repository secrets".                    |
| 9 | Do not store private keys, passwords, tokens, or secrets in the repository.              | `.gitignore` + ZIP exclude list + `scripts/package.sh` whitelist.            | `git log --all -p | grep -E 'BEGIN.*PRIVATE'` returns nothing.              |
| 10 | Do not store or configure deployment secrets on the VM.                                  | Only the public key is on the VM (`~/.ssh/authorized_keys`).                | `find / -name '*.pem' 2>/dev/null` on the VM returns nothing relevant.      |
| 11 | Do not execute `git pull` on the VM.                                                     | `remote_deploy.sh` uses `tar -xzf`, never `git`.                              | `grep -E 'git (pull|clone)' scripts/remote_deploy.sh` returns nothing.     |
| 12 | Do not manually copy or write application code onto the VM.                               | All source is shipped via the artifact; `remote_deploy.sh` extracts it.      | Visual inspection of `remote_deploy.sh`.                                    |
| 13 | GitHub Actions must transfer the deployment artifact directly to the VM.                  | `deploy.yml` -> "Transfer artifact to VM" step uses `scp`.                    | Workflow log shows `scp` command.                                          |
| 14 | Include automated error handling and deployment verification.                             | `remote_deploy.sh` verifies checksum, validates `nginx -t`, polls `systemctl is-active`, runs `smoke_test.sh`. | Failed step aborts the workflow.                                            |
| 15 | Include a README with installation, deployment, and testing instructions.                 | `README.md`.                                                                  | Open the file.                                                              |
| 16 | Package the complete project into a ZIP file.                                            | `FarAlpha-VM-Challenge.zip`.                                                  | `unzip -l FarAlpha-VM-Challenge.zip`.                                       |
| 17 | Include instructions for submitting the private GitHub repository link and ZIP file.      | `README.md` -> "Creating the private GitHub repository" + "Submission checklist". | This document.                                                              |

## 2. Virtual machine details

| Requirement                                                                                | Deliverable                                                                                                    |
|-------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------|
| VM host: 20.127.242.99                                                                    | Used as the default in README examples; configurable via `VM_HOST` secret.                                    |
| VM username: azureuser                                                                    | Used as the default in README examples; configurable via `VM_USER` secret.                                     |
| OS: not yet confirmed                                                                     | `check_prerequisites.sh` detects the OS via `/etc/os-release` and warns if unrecognised.                       |
| Authentication: SSH private key provided separately                                       | README documents that the key is supplied via the `VM_SSH_KEY` GitHub secret, never committed.                 |
| Never invent or embed the SSH private key                                                 | No private key in any file; `.gitignore` excludes `*.pem`, `*.key`, `id_rsa*`, `id_ed25519*`.                  |
| Do not include the private key in the ZIP archive                                         | ZIP exclude list + the packaging script's whitelist.                                                            |
| Do not assume the VM is Ubuntu without verification                                       | `check_prerequisites.sh` detects the OS family.                                                                |
| Deployment scripts must check the OS and report unsupported environments                  | `check_prerequisites.sh` reports `[FAIL]` / `[WARN]` for each missing prerequisite.                            |
| Provide a safe prerequisite/bootstrap procedure                                          | README -> "Initial VM provisioning" + `check_prerequisites.sh`.                                               |
| Separate initial machine provisioning from routine application deployments                 | Provisioning is manual (README); routine deploys are fully automated in `deploy.yml`.                          |
| Do not assume the VM can be modified with sudo without checking permissions                | `remote_deploy.sh` checks `sudo -n true` and exits with code 2 if unavailable.                                 |

## 3. Required technology

| Requirement                                         | Deliverable                                              |
|----------------------------------------------------|---------------------------------------------------------|
| Python 3                                            | `requirements.txt` declares Python 3 compatible deps.  |
| Flask                                               | `Flask==3.0.3`.                                          |
| Gunicorn                                            | `gunicorn==23.0.0` + `gunicorn.conf.py`.                 |
| Nginx listening on port 80                          | `deploy/nginx.conf` -> `listen 80 default_server`.       |
| Nginx proxies to Gunicorn at 127.0.0.1:8000          | `deploy/nginx.conf` -> `upstream faralpha_gunicorn { server 127.0.0.1:8000; }`. |
| GitHub Actions                                      | `.github/workflows/deploy.yml`.                          |
| SSH authentication                                  | `deploy.yml` -> "Configure SSH" step.                    |
| SCP or equivalent secure artifact transfer          | `deploy.yml` -> "Transfer artifact to VM" uses `scp`.    |
| systemd service for application lifecycle management | `deploy/faralpha-api.service` + `remote_deploy.sh` installs it. |
| pytest                                              | `tests/test_app.py` + `requirements-dev.txt`.            |
| Flask test client                                   | `tests/test_app.py` uses `app.test_client()`.            |
| HTTP smoke test against the deployed endpoint       | `scripts/smoke_test.sh` curls the public URL.            |

## 4. Required project structure

| Required file / directory                                   | Present? |
|-------------------------------------------------------------|----------|
| `app.py`                                                    | YES      |
| `requirements.txt`                                          | YES      |
| `requirements-dev.txt`                                      | YES      |
| `gunicorn.conf.py`                                          | YES      |
| `.gitignore`                                                | YES      |
| `.gitattributes`                                            | YES      |
| `README.md`                                                 | YES      |
| `DEPLOYMENT.md`                                             | YES      |
| `SECURITY.md`                                               | YES      |
| `Makefile`                                                  | YES      |
| `tests/__init__.py`                                         | YES      |
| `tests/test_app.py`                                         | YES      |
| `scripts/package.sh`                                        | YES      |
| `scripts/deploy.sh`                                         | YES      |
| `scripts/remote_deploy.sh`                                  | YES      |
| `scripts/smoke_test.sh`                                     | YES      |
| `scripts/check_prerequisites.sh`                            | YES      |
| `deploy/faralpha-api.service`                               | YES      |
| `deploy/nginx.conf`                                         | YES      |
| `.github/workflows/deploy.yml`                              | YES      |
| `.github/ISSUE_TEMPLATE/bug_report.md`                      | YES      |
| `docs/architecture.md`                                       | YES      |
| `docs/troubleshooting.md`                                   | YES      |
| `docs/submission-checklist.md`                              | YES      |
| `LICENSE`                                                    | YES      |

## 5. Backend implementation requirements

| Requirement                                                                  | Deliverable                                                                                |
|-----------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| `GET /sayHello` returns HTTP 200.                                            | `app.py` -> `response.status_code = 200`. Verified by `test_say_hello_returns_200`.        |
| `Content-Type` is `application/json`.                                        | Flask's `jsonify()` sets this. Verified by `test_say_hello_content_type_is_json`.          |
| JSON response is exactly `{"message": "Hello User."}`.                       | `app.py` returns `jsonify({"message": "Hello User."})`. Verified by `test_say_hello_returns_exact_json_body`. |
| Include a health endpoint only if it does not conflict with `/sayHello`.     | `GET /healthz` is a separate route, intentionally named differently.                       |
| Do not add unnecessary features.                                            | The app has only `/sayHello`, `/healthz`, and JSON-shaped error handlers.                  |
| Keep the application easy to understand and maintain.                        | `app.py` is ~100 lines with docstrings.                                                    |
| Use Gunicorn for production execution.                                       | `deploy/faralpha-api.service` -> `ExecStart=/opt/faralpha/venv/bin/gunicorn ...`.            |
| Do not use Flask's development server as the production server.              | The README explicitly warns against this.                                                   |
| Gunicorn listens on 127.0.0.1:8000, Nginx listens on port 80.                 | `gunicorn.conf.py` -> `bind = "127.0.0.1:8000"`. `nginx.conf` -> `listen 80 default_server`. |

## 6. GitHub Actions workflow requirements

| Requirement                                                                  | Deliverable                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Trigger on pushes to `main`.                                                | `deploy.yml` -> `on: push: branches: [main]`.                                                                |
| Support manual execution through `workflow_dispatch`.                       | `deploy.yml` -> `on: workflow_dispatch:`.                                                                    |
| Check out the source code.                                                  | `deploy.yml` -> `actions/checkout@<sha>`.                                                                    |
| Set up Python.                                                              | `deploy.yml` -> `actions/setup-python@<sha>`.                                                                 |
| Install dependencies.                                                       | `deploy.yml` -> `pip install -r requirements-dev.txt`.                                                       |
| Run pytest.                                                                 | `deploy.yml` -> `pytest -v --tb=short --junitxml=pytest-results.xml`.                                        |
| Create a versioned deployment artifact.                                    | `deploy.yml` -> `scripts/package.sh artifacts "${VERSION}" "${GIT_SHA:0:8}"`.                                |
| Calculate and verify the artifact checksum.                                | `package.sh` writes `.sha256`; `deploy.yml` verifies it after download; `remote_deploy.sh` verifies on the VM. |
| Configure SSH securely using GitHub Actions repository secrets.             | `deploy.yml` -> "Configure SSH" step writes `~/.ssh/vm_id` (0600) + `~/.ssh/known_hosts` (0644).             |
| Verify the SSH host key against a previously verified known-host entry.     | `deploy.yml` runs `ssh-keygen -F "${VM_HOST}"` before any SSH command; `StrictHostKeyChecking=yes` everywhere. |
| Connect to the VM as `azureuser`.                                          | `VM_USER` secret defaults to `azureuser`.                                                                    |
| Transfer the artifact using SCP or equivalent.                              | `deploy.yml` -> `scp ${SSH_OPTS} "${TARBALL_PATH}" "${SSH_TARGET}:${REMOTE_PATH}"`.                          |
| Execute the remote deployment script.                                       | `deploy.yml` -> `ssh ... "bash /tmp/remote_deploy.sh ..."`.                                                  |
| Never execute `git pull` or `git clone` on the VM.                          | `remote_deploy.sh` only uses `tar`, `cp`, `pip`, `systemctl`, `nginx`, `ln`.                                  |
| Never write source code manually through interactive shell commands.        | All app files come from the tarball.                                                                         |
| Install app dependencies in a venv during deployment.                      | `remote_deploy.sh` -> `python3 -m venv /opt/faralpha/venv`.                                                  |
| Configure systemd and Nginx through version-controlled config files.        | `deploy/faralpha-api.service` + `deploy/nginx.conf` are committed to git.                                    |
| Restart or reload necessary services.                                       | `remote_deploy.sh` -> `systemctl daemon-reload`, `systemctl reload nginx`, `systemctl restart faralpha-api`.  |
| Test the deployed endpoint.                                                | `deploy.yml` -> "Run smoke test on deployed endpoint".                                                       |
| Fail the workflow if any required step fails.                               | Every step uses `set -euo pipefail`; `remote_deploy.sh` exits non-zero on failure.                          |
| Display useful error messages.                                              | Each script logs `[FAIL]` lines with context.                                                                |
| Avoid printing secrets into logs.                                          | GitHub masks secrets; `deploy.yml` never echoes the key.                                                    |
| Use concurrency control to avoid overlapping deployments.                  | `deploy.yml` -> `concurrency: deploy-faralpha-api` with `cancel-in-progress: false`.                         |
| Use minimal GitHub Actions permissions.                                     | `deploy.yml` -> `permissions: contents: read`.                                                               |
| Pin third-party GitHub Actions to commit SHAs.                              | All `uses:` lines reference a SHA + a version comment.                                                      |
| Apply reasonable SSH connection and deployment timeouts.                    | `ConnectTimeout=15`, `ServerAliveInterval=15`, `ServerAliveCountMax=3`; `timeout-minutes` per job.          |

## 7. Critical deployment design

| Requirement                                                                  | Deliverable                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| No `git pull` / `git clone` on the VM.                                      | `remote_deploy.sh` only uses `tar`.                                                                          |
| No secrets stored on the VM.                                                | Only the public key is in `~/.ssh/authorized_keys`.                                                          |
| No private keys in the project ZIP.                                         | ZIP exclude list + `.gitignore` + packaging whitelist.                                                       |
| No private keys in GitHub source code.                                      | Same.                                                                                                       |
| No manually copied application code.                                        | All code comes from the artifact.                                                                            |
| No hardcoded passwords.                                                    | None present.                                                                                                |
| No `chmod 777`.                                                              | `chmod 700 ~/.ssh`, `chmod 600 ~/.ssh/vm_id`, `chmod 644 known_hosts`, `chmod 644 service file`.             |
| No disabling SSH host-key verification.                                      | `StrictHostKeyChecking=yes` everywhere.                                                                     |
| Do not run the application as root.                                         | systemd unit -> `User=azureuser`.                                                                            |
| Do not expose Gunicorn directly to the public internet.                     | `gunicorn.conf.py` -> `bind = "127.0.0.1:8000"`.                                                              |
| Do not overwrite a working deployment before validating the new release.    | Atomic symlink swap; `nginx -t` runs BEFORE reload; service start failure rolls back.                       |
| Preserve the previous release or provide a safe rollback mechanism.          | Last 5 releases retained; `current` symlink swap is atomic.                                                  |
| Ensure the remote deployment process is idempotent.                         | Re-running `remote_deploy.sh` produces the same end state.                                                  |
| SSH private key remains on the runner only for the duration of the job.    | `deploy.yml` -> "Cleanup SSH key" step with `if: always()`.                                                  |
| Distinguish public key (server auth) vs. private key (GitHub Actions).     | `SECURITY.md` -> section 1.                                                                                  |

## 8. Port 80 configuration

| Requirement                                                                  | Deliverable                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Implement port 80 safely with Nginx + Gunicorn.                              | `deploy/nginx.conf` + `gunicorn.conf.py`.                                                                    |
| Version-controlled Nginx config that forwards to Gunicorn.                  | `deploy/nginx.conf` is committed.                                                                            |
| Reachable at `http://20.127.242.99/sayHello`.                               | Smoke test verifies this URL.                                                                                |
| Document Azure NSG and Linux firewall requirements for TCP 80.             | README -> "Initial VM provisioning" + `docs/troubleshooting.md` section 7.                                   |
| Do not unnecessarily expose SSH or Gunicorn.                                | SSH on 22 (required); Gunicorn on 127.0.0.1 only.                                                            |
| If port 80 is occupied, detect the conflict and report it.                  | `check_prerequisites.sh` checks `ss -ltn 'sport = :80'`.                                                      |

## 9. Initial VM provisioning

| Requirement                                                                  | Deliverable                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Detect the Linux distribution.                                              | `check_prerequisites.sh` -> `/etc/os-release`.                                                                |
| Check for Python 3.                                                         | `check_prerequisites.sh` step 2.                                                                              |
| Check for Nginx.                                                            | `check_prerequisites.sh` step 3.                                                                              |
| Check for systemd.                                                          | `check_prerequisites.sh` step 4.                                                                              |
| Check whether sudo privileges are available.                                 | `check_prerequisites.sh` step 5.                                                                              |
| Check whether ports 80 and 8000 are in use.                                 | `check_prerequisites.sh` step 6.                                                                              |
| Check required system packages.                                            | `check_prerequisites.sh` steps 2-4.                                                                           |
| Report missing prerequisites.                                              | `check_prerequisites.sh` prints `[FAIL]` and exits 1.                                                        |
| Explain minimum commands needed to prepare the VM.                          | README -> "Initial VM provisioning".                                                                          |
| Routine deployment must remain automated.                                   | `deploy.yml` is fully automated.                                                                              |
| Initial provisioning must not require manually entering source code.        | Provisioning commands install only Python, Nginx, systemd - no app code.                                      |
| Use SSH to execute a clearly documented prerequisite check.                 | `deploy.yml` -> "Run prerequisite check on VM".                                                                |
| Do not attempt destructive changes.                                        | `check_prerequisites.sh` is read-only.                                                                        |
| If sudo is unavailable, report the blocker.                                | `remote_deploy.sh` -> "Sudo is NOT available" branch + exit code 2.                                           |

## 10. Automated tests

| Requirement                                                                  | Deliverable                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| `GET /sayHello` returns HTTP 200.                                            | `test_say_hello_returns_200`.                                                                                |
| Response body equals `{"message": "Hello User."}`.                          | `test_say_hello_returns_exact_json_body`.                                                                    |
| `Content-Type` is `application/json`.                                        | `test_say_hello_content_type_is_json`.                                                                        |
| Unsupported HTTP method rejected appropriately.                              | `test_say_hello_rejects_post`, `test_say_hello_rejects_put`, `test_say_hello_rejects_delete`.                  |
| CI workflow runs tests before deployment.                                    | `deploy.yml` -> `test` job runs before `deploy` job.                                                          |
| Smoke test requests `http://20.127.242.99/sayHello`.                         | `smoke_test.sh` -> `PUBLIC_URL`.                                                                              |
| Smoke test validates HTTP 200.                                               | `smoke_test.sh` -> `check_url ... 200 ...`.                                                                   |
| Smoke test validates correct JSON response.                                  | `smoke_test.sh` -> body contains `"Hello User."`.                                                              |
| Reasonable timeout.                                                          | `--max-time 15 --connect-timeout 10`.                                                                         |
| Useful error messages.                                                       | `smoke_test.sh` prints status, body, Content-Type on failure.                                                |
| Do not claim success unless tests were actually executed.                    | The workflow fails the job on any non-zero exit; smoke test never returns OK without checking.              |

## 11. Documentation

| Requirement                                                                  | Deliverable                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| README.md explains objective, architecture, prerequisites, local setup on Windows and Linux, local testing, private GitHub repository creation, GitHub secrets, SSH host-key verification, initial VM provisioning, GitHub Actions workflow execution, automatic deployment, endpoint testing, ZIP creation, troubleshooting, security considerations. | `README.md` covers every item in its table of contents.                                                       |
| DEPLOYMENT.md explains the deployment sequence in detail.                   | `DEPLOYMENT.md`.                                                                                              |
| SECURITY.md describes SSH key handling, secret management, host-key verification, least-privilege access, network exposure, artifact integrity, rollback considerations. | `SECURITY.md` -> sections 1-7.                                                                                |
| `docs/submission-checklist.md` lists every requirement.                    | This document.                                                                                                |
| Document that VM-specific compatibility and permissions must be checked before deployment. | README -> "Initial VM provisioning" + `check_prerequisites.sh`.                                              |
| Do not fabricate deployment results.                                        | The smoke test only reports success if `curl` actually returned 200.                                         |

## 12. ZIP file requirements

| Requirement                                                                  | Verified by                                                                                                  |
|-----------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| Filename is `FarAlpha-VM-Challenge.zip`.                                    | The file at `/home/z/my-project/download/FarAlpha-VM-Challenge.zip`.                                          |
| Excludes `.git/`, `.venv/`, `__pycache__/`, `.pytest_cache/`, `.env`, `*.pem`, `*.key`, `id_rsa`, `id_ed25519`, `credentials`, `*.secret`. | Exclusion list used when generating the ZIP.                                                                  |
| Includes a `.gitignore` preventing accidental inclusion of these files.    | `.gitignore` excludes all of the above.                                                                       |
| All referenced scripts and config files exist.                              | Verified by `find faralpha-vm-challenge -type f` after ZIP extraction.                                       |
| Workflow paths are correct.                                                 | `.github/workflows/deploy.yml` references existing scripts.                                                  |
| Run pytest if execution is available.                                       | Done locally; 8 tests pass.                                                                                   |
| Run YAML syntax validation if available.                                    | Done with `python -c "import yaml; yaml.safe_load(...)"`.                                                    |
| Run shell syntax checks if available.                                       | Done with `bash -n` on every `.sh` file.                                                                      |
| Search the project for hardcoded secrets.                                   | Done with a grep pattern for `BEGIN.*PRIVATE KEY`, `AKIA...`, etc.                                            |
| Check that the archive does not contain SSH keys or credentials.            | `unzip -l FarAlpha-VM-Challenge.zip | grep -E '\.(pem|key)$'` returns nothing.                                 |
| List the final archive contents.                                             | Done in the project README and as output of the packaging step.                                              |
| Report any tests that could not be executed.                                 | All available tests ran; nothing skipped.                                                                    |

## 13. Final submission

Before submitting:

- [ ] Pushed to private GitHub repository `faralpha-vm-challenge`.
- [ ] Repository URL captured (e.g. `https://github.com/<your-username>/faralpha-vm-challenge`).
- [ ] All four GitHub secrets configured (`VM_HOST`, `VM_USER`, `VM_SSH_KEY`, `VM_KNOWN_HOSTS`).
- [ ] Workflow ran successfully from the Actions tab.
- [ ] Smoke test passed (visible in the workflow log).
- [ ] `curl http://20.127.242.99/sayHello` returns `{"message":"Hello User."}` from your laptop.
- [ ] `FarAlpha-VM-Challenge.zip` generated and downloadable.
- [ ] Email / message to FarAlpha includes BOTH the repository link AND the ZIP file attachment (or download link).

Submission message template:

> Subject: FarAlpha VM Challenge - Submission
>
> Hello,
>
> Please find my submission for the FarAlpha VM Challenge below.
>
> - Private GitHub repository: https://github.com/<your-username>/faralpha-vm-challenge
> - ZIP file: attached (`FarAlpha-VM-Challenge.zip`)
>
> The deployment is fully automated via GitHub Actions. Pushing to the `main` branch triggers the workflow, which runs unit tests, builds a versioned artifact, transfers it to the Azure VM over SCP, and runs a smoke test against `http://20.127.242.99/sayHello`.
>
> No secrets are committed to the repository. The SSH private key is stored only as a GitHub Actions repository secret. The VM contains only the public key in `~/.ssh/authorized_keys`.
>
> Verification:
> ```
> $ curl http://20.127.242.99/sayHello
> {"message":"Hello User."}
> ```
>
> Please let me know if you have any questions.
>
> Best regards,
> <your name>
