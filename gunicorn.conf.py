# FarAlpha VM Challenge - Gunicorn configuration
# ---------------------------------------------------------------
# Gunicorn is the WSGI server that runs the Flask application in
# production. It binds ONLY to 127.0.0.1:8000 - it is never exposed
# directly to the public internet. Nginx on port 80 proxies inbound
# traffic to this Gunicorn socket.
#
# Documentation: https://docs.gunicorn.org/en/stable/settings.html

import multiprocessing
import os

# Bind to loopback only. Nginx is the only thing that should be able
# to reach Gunicorn. Public exposure is a security violation.
bind = "127.0.0.1:8000"

# Workers: 2 * CPU + 1 is the Gunicorn-recommended default for CPU
# bound workloads. For this trivial API 2-4 workers is plenty.
workers = int(os.environ.get("GUNICORN_WORKERS", str(min(4, (multiprocessing.cpu_count() * 2) + 1))))

# Use the sync worker class. This app is I/O-light, sync is fine and
# the simplest / most predictable choice.
worker_class = "sync"

# Per-worker timeout. Nginx will fail fast (proxy_read_timeout) before
# this fires, but we still set a sane upper bound.
timeout = 30

# Restart workers that have leaked memory or hung.
max_requests = 1000
max_requests_jitter = 50

# Clean up worker processes promptly on shutdown.
graceful_timeout = 10

# Logging: stdout so journald captures everything.
accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")

# Drop privileges is NOT done here because we run the service under a
# dedicated non-root user via systemd (User=azureuser). The process is
# already non-root by the time Gunicorn starts.

# Preload the application before forking workers. Reduces memory and
# speeds up boot - safe for stateless apps.
preload_app = True

# Disable Gunicorn's own daemonisation - systemd manages the lifecycle.
daemon = False

# PID file location (used by systemd for graceful restarts).
pidfile = "/tmp/faralpha-api.pid"
