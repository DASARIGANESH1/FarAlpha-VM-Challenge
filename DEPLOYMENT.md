# Deployment guide

This document describes the end-to-end deployment sequence in detail. It is intended for the reviewer who wants to understand exactly what happens when a `git push` reaches `main`, and for the operator who needs to debug a failed deploy.

---

## Sequence diagram

```
[ Push to main ]
        |
        v
+--------------------------+
| Job: test                |
|  - checkout              |
|  - setup-python          |
|  - pip install -r dev    |
|  - pytest                |  (fail-fast)
+--------------------------+
        |
        v
+--------------------------+
| Job: build-artifact     |
|  - checkout              |
|  - scripts/package.sh    |
|  - upload artifact        |
+--------------------------+
        |
        v
+----------------------------------+
| Job: deploy                      |
|  - download artifact              |
|  - sha256sum verify               |
|  - configure SSH from secrets    |
|  - ssh: check_prerequisites.sh    |  (fail-fast)
|  - scp: artifact -> /tmp          |
|  - scp: remote_deploy.sh          |
|  - scp: smoke_test.sh             |
|  - ssh: remote_deploy.sh          |
|  - ssh: smoke_test.sh             |
|  - cleanup ~/.ssh/vm_id           |
|  - GITHUB_STEP_SUMMARY            |
+----------------------------------+
        |
        v
[ http://<vm_host>/sayHello -> 200 OK ]
```

## Step-by-step description

### 1. Trigger

The workflow runs on:

- `push` to `main` (any commit).
- `workflow_dispatch` (manual trigger from the Actions UI).

A `concurrency` block groups runs under `deploy-faralpha-api` with `cancel-in-progress: false`, so:

- A new push does not interrupt a deploy that is already running.
- A queue of pending pushes collapses to the latest, but each one runs to completion.

### 2. Test job

- Checks out the source (pinned `actions/checkout@<sha>`).
- Sets up Python 3.11 (pinned `actions/setup-python@<sha>`) with pip caching keyed on `requirements*.txt`.
- Installs `requirements-dev.txt`.
- Runs `pytest -v --tb=short --junitxml=pytest-results.xml`.
- Uploads `pytest-results.xml` as a GitHub Actions artifact for visibility on the Actions UI.

If any test fails, the job fails and the workflow stops. No artifact is built. No deployment occurs.

### 3. Build-artifact job

- Checks out the source again (fresh runner).
- Sets the version string to `${GITHUB_RUN_NUMBER}-${GIT_SHA:0:8}` so every artifact has a unique, traceable name.
- Runs `scripts/package.sh artifacts <version> <short-sha>`:
  - Creates a staging directory.
  - Copies only the runtime-required files: `app.py`, `requirements.txt`, `gunicorn.conf.py`, `deploy/faralpha-api.service`, `deploy/nginx.conf`, `scripts/remote_deploy.sh`, `scripts/smoke_test.sh`.
  - Writes a `VERSION` manifest (name, version, git sha, built-at, built-on).
  - Writes a `MANIFEST` file listing every file in the artifact with its SHA-256.
  - `tar -czf` produces `artifacts/faralpha-api-<version>.tar.gz`.
  - `sha256sum` produces `artifacts/faralpha-api-<version>.tar.gz.sha256`.
- Exports `artifact_path`, `artifact_sha256`, `artifact_name` as job outputs.
- Uploads both files as a GitHub Actions artifact named `faralpha-api-artifact` with 7-day retention.

### 4. Deploy job

The deploy job depends on `build-artifact` and consumes its outputs.

#### 4.1 Download & verify artifact

- Downloads the GitHub Actions artifact (pinned `actions/download-artifact@<sha>`).
- Computes the SHA-256 of the tarball and compares against the value exported by the build job. A mismatch aborts the deploy.

#### 4.2 Configure SSH (from secrets)

- Reads `VM_SSH_KEY`, `VM_KNOWN_HOSTS`, `VM_HOST`, `VM_USER` from the GitHub Actions secret store.
- Each secret must be present and non-empty, otherwise the step aborts with a clear error message naming the missing secret.
- Writes `~/.ssh/vm_id` (mode 0600) with the private key.
- Writes `~/.ssh/known_hosts` (mode 0644) with the host key entries.
- Verifies that `known_hosts` actually contains an entry for `${VM_HOST}` (via `ssh-keygen -F`); aborts if not.
- Exports `SSH_OPTS` and `SSH_TARGET` as env vars for subsequent steps. The opts include:
  - `StrictHostKeyChecking=yes`
  - `ConnectTimeout=15`
  - `ServerAliveInterval=15`
  - `ServerAliveCountMax=3`

#### 4.3 Prerequisite check

- `scp` transfers `scripts/check_prerequisites.sh` to `/tmp/check_prerequisites.sh` on the VM.
- `ssh` runs `bash /tmp/check_prerequisites.sh` on the VM.
- The script checks Python 3, `python3-venv`, Nginx, systemd, sudo availability, port 80/8000 usage, and required directories.
- It is read-only - it does not install or modify anything.
- If any required prerequisite is missing, the script exits non-zero and the workflow halts BEFORE any artifact is transferred. This is a critical safety property: a half-prepared VM never receives a partial deployment.

#### 4.4 Transfer the artifact

- `scp` copies the tarball to `/tmp/faralpha-api-<version>.tar.gz` on the VM.
- The remote path is exported as `REMOTE_ARTIFACT_PATH` for later steps.

#### 4.5 Transfer the remote scripts

- `scp` copies `scripts/remote_deploy.sh` and `scripts/smoke_test.sh` to `/tmp/` on the VM. These scripts travel inside the artifact too, but shipping them separately lets the deploy job invoke them without first unpacking the artifact.

#### 4.6 Execute the remote deployment

- `ssh` invokes `bash /tmp/remote_deploy.sh <artifact_path> <expected_sha256>` on the VM.
- `remote_deploy.sh` performs the work described in its own header (see [scripts/remote_deploy.sh](scripts/remote_deploy.sh)). In summary:

  1. Verify the SHA-256 of the transferred artifact.
  2. Detect sudo availability (needed only for the systemd unit and the nginx site).
  3. Create `/opt/faralpha/{releases,staging,venv}`.
  4. Extract the tarball to a staging directory.
  5. Move the extracted tree to `/opt/faralpha/releases/<timestamp>/`.
  6. Create or refresh the virtualenv at `/opt/faralpha/venv/`.
  7. `pip install -r requirements.txt` inside the venv.
  8. Copy `deploy/faralpha-api.service` to `/etc/systemd/system/faralpha-api.service` (root-owned).
  9. `systemctl daemon-reload`.
  10. Copy `deploy/nginx.conf` to `/etc/nginx/sites-available/faralpha-api.conf` (root-owned).
  11. Symlink `/etc/nginx/sites-enabled/faralpha-api.conf` -> the file above.
  12. Remove the `default` site symlink if present (frees port 80).
  13. `nginx -t` - refuse to reload if the config is broken (rolls back the service file).
  14. `systemctl reload nginx`.
  15. Atomically swap `/opt/faralpha/current` to point at the new release (uses `ln -sfn ... .new && mv -Tf .new current`).
  16. `systemctl restart faralpha-api`.
  17. Poll `systemctl is-active` for up to 5 seconds; if the service fails to start, roll back to the previous release automatically.
  18. Cleanup old releases, keeping the most recent 5.

#### 4.7 Run the smoke test

- `ssh` invokes `bash /tmp/smoke_test.sh <vm_host>` on the VM.
- The smoke test exercises three URLs with `curl`:
  1. `http://127.0.0.1:8000/healthz` - confirms Gunicorn is alive directly.
  2. `http://127.0.0.1:8000/sayHello` - confirms Gunicorn serves the route.
  3. `http://<vm_host>/sayHello` - confirms Nginx is proxying correctly on port 80.
- Also checks the `Content-Type: application/json` header on the public endpoint.
- Any failure aborts the workflow (the deployment is considered failed even if the service is technically running).

#### 4.8 Cleanup

- `rm -f ~/.ssh/vm_id` on the runner - the private key is destroyed.
- Best-effort cleanup of `/tmp/*` on the VM (wrapped in `|| true` so this never fails the deploy).
- The `if: always()` ensures cleanup runs even if an earlier step failed.

#### 4.9 Summary

A markdown summary is written to `$GITHUB_STEP_SUMMARY` showing the artifact name, SHA-256, VM host, and the deployed endpoint URL.

## Rollback

Rollback is automatic on service-start failure: the previous release is restored and the service is restarted. If a deploy succeeds but you later want to manually roll back:

```bash
ssh azureuser@20.127.242.99
cd /opt/faralpha/releases
ls -1dt */                   # see the most recent releases
PREV=$(ls -1dt */ | sed -n '2p' | tr -d '/')
sudo cp "${PREV}/deploy/faralpha-api.service" /etc/systemd/system/faralpha-api.service
sudo cp "${PREV}/deploy/nginx.conf" /etc/nginx/sites-available/faralpha-api.conf
sudo ln -sfn "/opt/faralpha/releases/${PREV}" /opt/faralpha/current
sudo systemctl daemon-reload
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl restart faralpha-api
bash /opt/faralpha/current/scripts/smoke_test.sh localhost
```

## Idempotency

Re-running `remote_deploy.sh` against the same artifact:

- Produces a new timestamped release directory (so `current` is updated, not overwritten).
- Reinstalls Python dependencies inside the existing venv (pip is idempotent for already-satisfied deps).
- Re-copies the systemd unit and nginx site config (no-op if unchanged).
- Reloads nginx only if `nginx -t` passes.
- Restarts `faralpha-api` once.

Two consecutive runs therefore converge to the same end state.

## Failure handling

| Failure point                            | What happens                                                                                                |
|------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| pytest fails                             | Workflow halts. No artifact is built. No deploy occurs.                                                     |
| Artifact checksum mismatches on download | Deploy job aborts. Re-run the workflow.                                                                    |
| SSH secret missing                       | Deploy job aborts with a named error. Add the missing secret in the repo settings.                          |
| Prerequisite check fails                 | Workflow aborts BEFORE the artifact is transferred. VM remains untouched. Provision the VM and re-run.       |
| `nginx -t` fails                         | `remote_deploy.sh` restores the previous service file, refuses to reload nginx, exits non-zero.             |
| `systemctl restart` fails                | `remote_deploy.sh` rolls back the `current` symlink to the previous release and restarts the service.       |
| Smoke test fails                         | Workflow fails. SSH in and inspect `systemctl status faralpha-api` and `journalctl -u faralpha-api`.        |

## Timeouts

| Job      | `timeout-minutes` |
|----------|-------------------|
| test     | 10                |
| build-artifact | 10            |
| deploy   | 15                |

In addition, the SSH options include `ConnectTimeout=15`, `ServerAliveInterval=15`, `ServerAliveCountMax=3`, so a hung SSH session is killed within ~60 seconds rather than running the deploy job to its 15-minute limit.
