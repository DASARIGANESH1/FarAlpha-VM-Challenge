# Troubleshooting

Common failures and their fixes. Each entry follows the pattern: **Symptom -> Cause -> Fix**.

---

## 1. Workflow fails at "Configure SSH"

### Symptom

```
ERROR: VM_SSH_KEY secret is not set
ERROR: VM_KNOWN_HOSTS secret is not set
ERROR: VM_HOST or VM_USER secret is not set
```

### Cause

One of the four required repository secrets is missing or empty.

### Fix

Go to **Settings -> Secrets and variables -> Actions -> New repository secret** and create the missing entries:

- `VM_HOST` = `20.127.242.99`
- `VM_USER` = `azureuser`
- `VM_SSH_KEY` = the full PEM contents of the SSH private key
- `VM_KNOWN_HOSTS` = output of `ssh-keyscan -H 20.127.242.99`

Re-run the workflow.

---

## 2. Workflow fails at "Run prerequisite check on VM"

### Symptom

```
[FAIL] python3 not found
[FAIL] nginx not found
[FAIL] systemd is required to manage the application service
```

### Cause

The VM has not been provisioned yet (Python, Nginx, or systemd is missing).

### Fix

SSH into the VM with the employer-provided key and install the prerequisites:

```bash
ssh -i /path/to/employer-key.pem azureuser@20.127.242.99

# Detect OS:
cat /etc/os-release

# Ubuntu/Debian:
sudo apt-get update
sudo apt-get install -y nginx python3 python3-venv python3-pip

# RHEL/CentOS/Rocky/Alma:
sudo dnf install -y nginx python3

# Enable and start nginx:
sudo systemctl enable --now nginx
```

Then re-run the prerequisite check:

```bash
bash /tmp/check_prerequisites.sh
```

You should see `[ OK ]` for every check.

---

## 3. Workflow fails at "Verify artifact checksum"

### Symptom

```
Expected SHA256: abc123...
Actual   SHA256: def456...
ERROR: checksum mismatch
```

### Cause

The artifact was corrupted during upload or download (rare; usually indicates transient runner disk issues).

### Fix

Re-run the failed workflow. If the problem persists, check that the GitHub Actions runner has adequate disk space and that the network connection to GitHub is stable.

---

## 4. Workflow fails at "Transfer artifact to VM"

### Symptom

```
scp: /tmp/faralpha-api-<version>.tar.gz: Permission denied
```

### Cause

The `azureuser` account on the VM cannot write to `/tmp/`. This is unusual but can happen on hardened systems where `/tmp` is mounted `noexec` or has strict ACLs.

### Fix

Change `REMOTE_ARTIFACT_PATH` in `.github/workflows/deploy.yml` to a path the user can write to, e.g.:

```bash
REMOTE_PATH="/home/azureuser/$(basename "${TARBALL_PATH}")"
```

Then commit and push.

---

## 5. Workflow fails at "Execute remote deployment"

### Symptom 1: checksum mismatch on the VM

```
[deploy][ERROR] Checksum mismatch!
  expected: abc123...
  actual:   def456...
```

### Cause

The artifact was corrupted during the SCP transfer (network glitch).

### Fix

Re-run the workflow. If it persists, check the network connection between the GitHub Actions runner and the VM.

### Symptom 2: nginx -t fails

```
nginx: [emerg] ...
[deploy][ERROR] nginx -t reported a syntax error - refusing to reload.
```

### Cause

The `deploy/nginx.conf` file is syntactically invalid or incompatible with the nginx version on the VM.

### Fix

SSH into the VM, inspect the error:

```bash
sudo nginx -t
```

Fix the syntax in `deploy/nginx.conf`, commit, and push. The previous service file will have been restored automatically.

### Symptom 3: systemctl restart fails

```
[deploy][ERROR] Service failed to start within 5s.
[deploy][ERROR] Journal tail:
... full traceback ...
```

### Cause

A Python-level failure (import error, syntax error in `app.py`, missing dependency).

### Fix

SSH in and reproduce:

```bash
sudo journalctl -u faralpha-api -n 100 --no-pager
# Or run the WSGI app directly:
cd /opt/faralpha/current
/opt/faralpha/venv/bin/python -c "from app import application; print(application)"
```

Fix the underlying issue, commit, push.

The previous release will have been restored automatically as part of the rollback logic.

---

## 6. Workflow fails at "Run smoke test on deployed endpoint"

### Symptom

```
[FAIL] Status 502, expected 200
```

### Cause

Gunicorn is up but returning an error, OR Nginx cannot reach Gunicorn.

### Fix

```bash
ssh azureuser@20.127.242.99

# Is the service actually running?
sudo systemctl status faralpha-api

# What did the service log?
sudo journalctl -u faralpha-api -n 100 --no-pager

# Can you hit Gunicorn directly (bypassing Nginx)?
curl -v http://127.0.0.1:8000/sayHello

# What does Nginx say about it?
sudo tail -n 100 /var/log/nginx/faralpha-api-error.log
```

Common causes:

- `app.py` raised on import (missing dependency).
- The venv was not actually populated (check `/opt/faralpha/venv/bin/python -c 'import flask, gunicorn'`).
- Gunicorn is bound to a different port (check `ss -ltnp | grep 8000`).

### Symptom 2: timeout

```
[FAIL] Request failed (curl error) for http://20.127.242.99/sayHello
```

### Cause

The Azure NSG is not allowing inbound TCP 80, OR the Linux firewall is blocking it, OR the service is not running.

### Fix

- In the Azure Portal: VM -> Networking -> Confirm there is an inbound rule for port 80 from the Internet.
- On the VM: `sudo ufw status` (Ubuntu) or `sudo firewall-cmd --list-all` (RHEL). Allow port 80 if needed.
- Restart the service: `sudo systemctl restart faralpha-api`.

---

## 7. `curl http://20.127.242.99/sayHello` times out from your laptop

### Cause

Public network reachability issue. The CI smoke test passes (because it runs from the VM, hitting the loopback), but external clients cannot reach port 80.

### Fix

1. Confirm the VM is running and the service is up:

```bash
ssh azureuser@20.127.242.99
sudo systemctl status faralpha-api
curl -v http://127.0.0.1/sayHello
```

2. Check the Azure NSG: VM -> Networking -> Add inbound port rule for port 80, Tcp, Internet, Allow, priority 1000.
3. Check the Linux firewall:

```bash
sudo ufw status
sudo ufw allow 80/tcp
```

---

## 8. `systemctl status faralpha-api` shows the service is "failed"

### Symptom

```
Active: failed (Result: exit-code)
```

### Cause

Application-level crash.

### Fix

```bash
# Get the last 100 log lines:
sudo journalctl -u faralpha-api -n 100 --no-pager

# Try running the app directly to see the error:
cd /opt/faralpha/current
/opt/faralpha/venv/bin/python -c "from app import application; print('OK')"
```

Common fixes:

- A new requirement was added to `requirements.txt` but the venv is stale. Manually run `pip install -r requirements.txt` inside the venv, then `sudo systemctl restart faralpha-api`.
- The systemd unit has a typo. Check `cat /etc/systemd/system/faralpha-api.service` against the version-controlled file.

---

## 9. `git push` is rejected because of the private key in the repo

### Symptom

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: Review repository rules and try again.
```

### Cause

A file matching the secret patterns in `.gitignore` was force-added to git.

### Fix

Remove the file from the index (but not from disk):

```bash
git rm --cached path/to/secret.pem
git commit -m "Remove accidentally committed secret"
git push
```

If the file is already in git history, you will need to rewrite history (use `git filter-repo` or BFG Repo-Cleaner). Rotate the leaked key immediately.

---

## 10. The application works locally but not on the VM

### Symptom

`make test` passes locally. The deployed endpoint returns `{"error":"bad_gateway"}`.

### Cause

A Python version mismatch (e.g. you tested with 3.12 locally, but the VM has 3.8). Some syntax (e.g. `match` statements) requires 3.10+.

### Fix

Pin the Python version on the VM, or test locally with the same version. The CI workflow uses 3.11 - match that locally to catch issues early.

---

## 11. The previous release is gone after a deploy

### Symptom

`/opt/faralpha/releases/` only has the current release.

### Cause

The cleanup logic ran before the rollback could trigger, OR more than 5 deploys have happened.

### Fix

This is by design - only the last 5 releases are retained. If you need to roll back further, you must trigger the workflow again with an older commit. The artifact is also retained in GitHub Actions for 7 days.

---

## 12. Workflow takes too long

### Symptom

Deploy job runs for ~15 minutes and times out.

### Cause

SSH connection is slow (network issue between GitHub Actions runner and the VM), or `pip install` is rebuilding wheels repeatedly.

### Fix

- Check the VM's network connectivity. The GitHub Actions runner is hosted by GitHub; some Azure regions have known connectivity issues.
- Ensure `pip` is upgraded before install (the `remote_deploy.sh` script does this).
- If `pip install` is slow, consider adding `--no-cache-dir` to the install command in `remote_deploy.sh`.

---

If none of the above resolves your issue, open a bug report using the template at `.github/ISSUE_TEMPLATE/bug_report.md`.
