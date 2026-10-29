# Security policy

This document describes the threat model and the security controls implemented in the FarAlpha VM Challenge project.

---

## 1. SSH key handling

### Public vs. private key

There are two distinct SSH keys in this project:

| Key            | Where it lives                                                        | Purpose                                          |
|----------------|------------------------------------------------------------------------|--------------------------------------------------|
| Public key     | `~/.ssh/authorized_keys` on the Azure VM (`azureuser@20.127.242.99`). | Allows the VM to authenticate the SSH client.    |
| Private key    | GitHub Actions repository secret `VM_SSH_KEY`.                          | Used by the GitHub Actions runner to authenticate to the VM. |

The VM has **only** the public key. It cannot be used to log into anything; it can only verify signatures produced by the matching private key. The private key is held by GitHub as an encrypted repository secret and is only ever written to the ephemeral runner's filesystem for the duration of a deploy job. At the end of the job the file `~/.ssh/vm_id` is removed (in an `if: always()` step so this runs even on failure).

### Why this satisfies "no secrets on the VM"

A secret is something whose disclosure would let an attacker impersonate a trusted party. The public key is, by definition, not secret - it is safe to leave it on disk. The private key, which IS the secret, never touches the VM's disk. Even if an attacker captured the entire VM filesystem, they could not use it to authenticate to GitHub or to any other system.

### Key hygiene

- The `.gitignore` excludes `*.pem`, `*.key`, `id_rsa`, `id_rsa.*`, `id_ed25519`, `id_ed25519.*`, `*.ppk`, `.env`, `.env.*`, `secrets.*`, `credentials`, `*.secret`, `.ssh/`, `known_hosts`, `*.token`.
- The packaging script (`scripts/package.sh`) only copies a fixed whitelist of files into the artifact; even if a stray key file existed in the repo, it would not be packaged.
- The submission ZIP is generated with explicit exclusions for these patterns.

## 2. Secret management

### Which secrets are required

| Name              | Type             | Used by                |
|-------------------|------------------|------------------------|
| `VM_HOST`         | Public IP string | SSH commands           |
| `VM_USER`         | Username string  | SSH commands           |
| `VM_SSH_KEY`      | PEM private key  | SSH authentication     |
| `VM_KNOWN_HOSTS`  | `known_hosts` lines | Host-key verification  |

### How they are stored

GitHub Actions encrypts repository secrets at rest with AES-256-GCM. They are decrypted only on the runner that executes the workflow, and only when an explicit `env:` block references them. They are NEVER printed in workflow logs: GitHub masks any value that matches a configured secret, and the workflow never echoes the key contents.

### What is NOT a secret

The contents of `requirements.txt`, `gunicorn.conf.py`, `nginx.conf`, and the systemd unit are intentionally public. Reviewers should be able to read them. The only things that need protection are the SSH key and the host's identity.

## 3. Host-key verification

`StrictHostKeyChecking=yes` is set on every SSH and SCP invocation in the workflow. The `known_hosts` file is populated from the `VM_KNOWN_HOSTS` secret, NOT from the runner's default `~/.ssh/known_hosts`.

Before any deploy step runs, the workflow verifies that `known_hosts` actually contains an entry for `${VM_HOST}`:

```bash
ssh-keygen -F "${VM_HOST}" -f ~/.ssh/known_hosts >/dev/null || {
    echo "ERROR: VM_KNOWN_HOSTS does not contain an entry for ${VM_HOST}" >&2
    exit 1
}
```

If the entry is missing or malformed, the workflow fails fast. This prevents the deployment from silently accepting a man-in-the-middle attack if the VM's IP is ever reassigned.

### How to obtain and verify the host key

See the [README - Obtaining and verifying the SSH host key](README.md#obtaining-and-verifying-the-ssh-host-key) section. The summary:

1. From a trusted machine, run `ssh-keyscan -H <VM_HOST>` to obtain the host key.
2. Cross-check the fingerprint by SSHing into the VM through a trusted channel and running `ssh-keygen -l -f /etc/ssh/ssh_host_ed25519_key.pub`.
3. Paste the `ssh-keyscan` output into the `VM_KNOWN_HOSTS` secret.

## 4. Least-privilege access

### GitHub Actions permissions

The workflow sets:

```yaml
permissions:
  contents: read
```

This is the absolute minimum - the workflow can read the repo content (for checkout) but cannot push commits, modify issues, or change settings. No other permissions are requested.

### Pinned third-party actions

All `uses:` declarations in the workflow reference a specific commit SHA, not a tag:

```yaml
uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
```

This means a compromised tag (e.g. an attacker retagging `v4` to point at a malicious commit) cannot affect our build. The trailing comment records the human-readable version for reviewers.

### VM user privileges

- The application service runs as `azureuser`, a non-root account. The systemd unit enforces `User=azureuser`, `Group=azureuser`.
- The systemd unit additionally sets:
  - `NoNewPrivileges=true` - the process cannot escalate via setuid binaries.
  - `ProtectSystem=full` - `/usr`, `/boot`, `/etc` are read-only to the process.
  - `ProtectHome=true` - `/home`, `/root`, `/run/user` are inaccessible.
  - `ProtectKernelTunables=true`, `ProtectKernelModules=true`, `ProtectControlGroups=true`.
  - `RestrictSUIDSGID=true`, `RestrictNamespaces=true`, `LockPersonality=true`.

These settings make it harder for an application compromise to translate into a full VM compromise.

### Why sudo is needed (and only for provisioning)

- `remote_deploy.sh` writes to `/etc/systemd/system/` and `/etc/nginx/sites-available/`. Those directories are root-owned.
- It uses `sudo` only for those writes and for `systemctl daemon-reload`, `nginx -t`, `systemctl reload nginx`, `systemctl restart faralpha-api`.
- All other operations (venv creation, pip install, tarball extraction, the `current` symlink swap) happen in `/opt/faralpha/`, which is owned by `azureuser`.

## 5. Network exposure

| Service    | Listen address        | Publicly reachable | Reason                                |
|------------|------------------------|--------------------|----------------------------------------|
| Nginx      | `0.0.0.0:80`           | YES                | The assignment requires port 80 to be reachable. |
| Gunicorn   | `127.0.0.1:8000`       | NO                 | Bound to loopback only; only Nginx can reach it. |
| SSH        | `0.0.0.0:22` (default) | YES                | Required for GitHub Actions; lock down via NSG to GitHub Actions IP ranges if possible. |

The Nginx configuration explicitly refuses to expose any route other than `/sayHello` and `/healthz`:

```nginx
location / {
    return 404;
}
```

So even if an attacker scanned the VM, they would not find an undocumented route.

### Azure NSG / firewall requirements

The Azure VM has a Network Security Group (NSG) that controls inbound traffic. For the deployment to be reachable:

| Priority | Port | Protocol | Source           | Action |
|----------|------|----------|-------------------|--------|
| 1000     | 80   | Tcp      | Internet          | Allow  |
| 100      | 22   | Tcp      | Internet (or GitHub Actions IP ranges, ideally) | Allow  |
| 65000    | *    | *        | *                 | Deny   |

The Linux firewall (`ufw` or `firewalld`) must also allow port 80 inbound. See the README's provisioning section for the commands.

### SSH exposure

If the VM is shared with other candidates, consider restricting SSH to GitHub Actions IP ranges (https://api.github.com/meta) for additional hardening. The project does not assume this is configured - it only requires that the GitHub Actions runner can reach port 22.

## 6. Artifact integrity

### Build-time

- `scripts/package.sh` produces the tarball.
- It computes the SHA-256 of the tarball and writes it to `<tarball>.sha256`.
- It also writes a `MANIFEST` file inside the tarball listing every contained file with its own SHA-256.

### Transfer-time

- The deploy job reads the SHA-256 from the build job's outputs (`needs.build-artifact.outputs.artifact-sha256`).
- After downloading the artifact, it recomputes the SHA-256 and compares. A mismatch aborts the deploy.

### Run-time

- `remote_deploy.sh` receives `<artifact_path> <expected_sha256>` as positional arguments.
- It recomputes the SHA-256 of the file on the VM and compares with the expected value.
- A mismatch (which would indicate tampering or transfer corruption) aborts the deploy BEFORE extraction.

These three layers ensure that a corrupted or tampered artifact cannot reach the runtime.

## 7. Rollback considerations

### Automatic rollback

If `systemctl restart faralpha-api` fails to bring the service up (within 5 seconds, polled once per second), `remote_deploy.sh`:

1. Restores the previous systemd unit file from the prior release directory.
2. Reloads systemd.
3. Swaps the `current` symlink back to the previous release.
4. Restarts the service.
5. Exits non-zero (so the workflow fails, but the VM is left in a known-good state).

### Manual rollback

See [DEPLOYMENT.md - Rollback](DEPLOYMENT.md#rollback). The previous release directories are retained in `/opt/faralpha/releases/` for at least 5 deployments.

### What is NOT rolled back automatically

- The Nginx site config. If `nginx -t` fails, the deploy refuses to reload Nginx and restores the previous systemd unit, but the nginx site file may have been overwritten. The operator should manually copy the previous `deploy/nginx.conf` back if needed.
- The Python dependencies in the venv. `pip install` is additive; if a new dependency is broken, the venv still has the old version (until `pip install` overwrites it). For mission-critical deploys, consider using a per-release venv.

## 8. Reporting a security issue

If you discover a vulnerability in this project, please do NOT open a public issue. Instead, email the repository owner directly. The threat model in this document is the canonical reference for what we consider in-scope.
