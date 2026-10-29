# Architecture

This document is the canonical reference for the system architecture. It expands on the diagram in the README with the rationale behind each design choice.

---

## 1. Components

### 1.1 Flask application (`app.py`)

A minimal Flask app exposing:

- `GET /sayHello` - returns `{"message": "Hello User."}` with HTTP 200 and `Content-Type: application/json`.
- `GET /healthz` - returns `{"status":"ok"}` with HTTP 200. Used by the smoke test to verify the service is alive before validating the application route. This endpoint does not replace `/sayHello` - it is intentionally named differently to avoid any ambiguity.

The app uses an application factory (`create_app()`) so pytest can construct a fresh instance per test. Error handlers guarantee that 404, 405, and 500 responses are JSON-shaped (the API never returns an HTML error page).

The Flask development server is NEVER used in production. The app is imported as a WSGI callable (`app:application`) by Gunicorn.

### 1.2 Gunicorn (`gunicorn.conf.py`)

Gunicorn is the WSGI server. Key configuration:

- `bind = "127.0.0.1:8000"` - loopback only. Gunicorn is never exposed directly to the public internet. This is a hard security invariant.
- `workers` - default to `min(4, 2*cpu+1)`. Sync worker class is used because the app is I/O-light.
- `max_requests = 1000` + `max_requests_jitter = 50` - workers are recycled to prevent memory leaks.
- `preload_app = True` - the app is loaded once before forking workers, reducing memory usage.
- `daemon = False` - systemd manages the lifecycle; Gunicorn must not fork into the background.
- Logging goes to stdout/stderr so journald captures it.

### 1.3 systemd service (`deploy/faralpha-api.service`)

The service runs Gunicorn as a non-root user (`azureuser`) and includes hardening directives:

- `Type=notify` - Gunicorn signals readiness to systemd.
- `Restart=on-failure` with `RestartSec=2s`, `StartLimitBurst=5`, `StartLimitIntervalSec=60` - the service auto-restarts on crash with a sane backoff.
- `KillSignal=SIGTERM` + `TimeoutStopSec=20` - graceful shutdown.
- Hardening: `NoNewPrivileges`, `ProtectSystem=full`, `ProtectHome`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID`, `RestrictNamespaces`, `LockPersonality`.

### 1.4 Nginx site (`deploy/nginx.conf`)

- `listen 80 default_server` - the assignment requires port 80.
- An `upstream faralpha_gunicorn` block defines the Gunicorn backend.
- Explicit `location` blocks for `/sayHello` and `/healthz` - any other path returns 404.
- `proxy_set_header` directives ensure the app sees the real client IP and protocol.
- Sensible timeouts: `proxy_connect_timeout 5s`, `proxy_send_timeout 30s`, `proxy_read_timeout 30s`.
- JSON-shaped error pages for 404 and 5xx so the API contract is consistent even on errors.

### 1.5 GitHub Actions workflow (`.github/workflows/deploy.yml`)

Three jobs:

1. `test` - pytest gate.
2. `build-artifact` - `package.sh` produces the tarball + checksum.
3. `deploy` - download artifact, verify checksum, configure SSH from secrets, run prerequisite check, scp artifact, run `remote_deploy.sh`, run `smoke_test.sh`, cleanup.

Concurrency control queues runs (does not cancel in-progress deploys). Minimal `permissions: contents: read`. All third-party actions pinned to commit SHAs.

### 1.6 Deployment scripts (`scripts/`)

- `check_prerequisites.sh` - read-only VM check.
- `package.sh` - builds the artifact locally.
- `deploy.sh` - manual wrapper (not used by CI; included for completeness).
- `remote_deploy.sh` - runs on the VM.
- `smoke_test.sh` - runs on the VM.

### 1.7 Tests (`tests/`)

Eight pytest cases covering:

- HTTP 200 on `GET /sayHello`.
- Exact JSON body `{"message":"Hello User."}`.
- `Content-Type: application/json`.
- Byte-for-byte body equality (with tolerant fallback for separator variants).
- 405 on POST, PUT, DELETE.
- 200 on `GET /healthz`.

## 2. Data flow

```
[Client] --HTTP--> Nginx:80 --HTTP--> Gunicorn:8000 --WSGI--> Flask app
                                                            |
                                                            v
                                                  {"message":"Hello User."}
```

The client only ever sees Nginx. Gunicorn is bound to loopback and unreachable from outside the VM.

## 3. Deployment flow

See [DEPLOYMENT.md](../DEPLOYMENT.md).

## 4. Design decisions and rationale

### 4.1 Why a separate `healthz` endpoint?

The assignment requires `/sayHello` to return a specific JSON payload. If we re-used `/sayHello` as the liveness probe, the smoke test could not distinguish "the service is up but the route is wrong" from "the service is down". A separate `/healthz` route decouples these two concerns. It is named differently on purpose so there is no ambiguity with the required application route.

### 4.2 Why a versioned release directory with an atomic symlink swap?

A direct overwrite of `/opt/faralpha/current` would create a window during which the directory is half-populated. A timestamped release directory + `ln -sfn .new && mv -Tf .new current` swap is atomic at the filesystem level: the `current` link always points at a fully-populated release.

### 4.3 Why keep 5 releases?

- The most recent release is the rollback target.
- Older releases are useful for bisecting if a deploy introduces a regression that is only detected later.
- 5 is a sane upper bound that prevents unbounded disk growth.

### 4.4 Why disable the nginx default site?

The default nginx site listens on port 80 and serves a placeholder page. Leaving it enabled would conflict with our `default_server` declaration. We disable the symlink rather than deleting the file so the operator can re-enable it if they want.

### 4.5 Why is `pip install` run inside the venv (not as root)?

- `pip install` as root can overwrite system packages, breaking other services on the VM.
- A venv isolates the application dependencies from the system Python.
- The venv lives at `/opt/faralpha/venv/` and is reused across deployments (creating a fresh venv per deploy would be slow and wasteful).

### 4.6 Why SCP instead of `rsync` over SSH?

- `scp` is available on every GitHub Actions runner without additional setup.
- `rsync` would require installing it on the runner (and potentially on the VM).
- The artifact is small (a few hundred KB), so the perf advantage of `rsync` is irrelevant.

### 4.7 Why run the prerequisite check from the VM, not from the runner?

The check is read-only and produces clear `[ OK ]` / `[FAIL]` lines. Running it on the VM (via SSH) verifies the actual state of the VM, not the runner's view of the VM. It also catches issues like "port 80 is already in use by something else" that the runner cannot easily detect.

### 4.8 Why pin actions to commit SHAs?

GitHub tag refs are mutable. If an attacker compromised a popular action's repo and re-tagged `v4` to point at a malicious commit, every workflow using `actions/checkout@v4` would silently switch to the malicious version. Pinning to a SHA makes the dependency immutable. We keep the version comment for readability.

## 5. Threat model

| Threat                                              | Mitigation                                                                                         |
|-----------------------------------------------------|----------------------------------------------------------------------------------------------------|
| Stolen private SSH key in git history                | `.gitignore` excludes key patterns; packaging script only copies whitelisted files.                |
| Stolen private SSH key from the runner              | Key file is removed in an `if: always()` cleanup step.                                            |
| Man-in-the-middle on SSH                             | `StrictHostKeyChecking=yes` + `VM_KNOWN_HOSTS` secret verified before any deploy step.            |
| Tampered artifact in transit                         | SHA-256 verified at build, after download, and on the VM before extraction.                         |
| Compromised GitHub Actions third-party action        | All actions pinned to commit SHAs.                                                                |
| Application compromise leading to full VM compromise | systemd unit hardening (NoNewPrivileges, ProtectSystem, etc.); non-root execution.                |
| Public exposure of Gunicorn                          | Gunicorn binds only to 127.0.0.1:8000; only Nginx is publicly reachable.                            |
| Two deploys racing on the same VM                    | `concurrency: deploy-faralpha-api` with `cancel-in-progress: false`.                              |
| Half-deployment leaves VM in broken state            | Atomic symlink swap + automatic rollback on service start failure.                                  |
| Unbounded disk growth from old releases              | `remote_deploy.sh` retains only the last 5 releases.                                               |
| Secrets leaking into logs                            | GitHub masks configured secret values; workflow never echoes the key contents.                     |
| Accidental secret commit                             | `.gitignore` + `.gitattributes` + the ZIP exclude list.                                            |
