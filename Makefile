# ---------------------------------------------------------------
# FarAlpha VM Challenge - Makefile
# ---------------------------------------------------------------
# Common developer commands. Run `make help` to see them all.
# ---------------------------------------------------------------

.PHONY: help venv install install-dev test lint clean package deploy-local smoke

PYTHON ?= python3
VENV ?= .venv
PIP := $(VENV)/bin/pip
PYTEST := $(VENV)/bin/pytest

help: ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

venv: ## Create a Python virtualenv at $(VENV).
	$(PYTHON) -m venv $(VENV)
	$(PIP) install --upgrade pip

install: venv ## Install runtime dependencies.
	$(PIP) install -r requirements.txt

install-dev: venv ## Install runtime + dev dependencies.
	$(PIP) install -r requirements-dev.txt

test: ## Run pytest with coverage.
	$(PYTEST) -v --tb=short

test-ci: ## Run pytest the way CI does (no venv required).
	pytest -v --tb=short

run: install ## Run the Flask dev server locally (NOT for production).
	$(VENV)/bin/flask --app app run --host 127.0.0.1 --port 5000

gunicorn: install ## Run Gunicorn locally (production-like).
	$(VENV)/bin/gunicorn --config gunicorn.conf.py "app:application"

package: ## Build the deployment artifact locally.
	bash scripts/package.sh artifacts local "$(shell date -u '+%Y%m%d%H%M%S')"

deploy-local: ## Deploy to a VM manually. Usage: make deploy-local HOST=x USER=y KEY=z
	@if [ -z "$(HOST)" ]; then echo "Usage: make deploy-local HOST=20.127.242.99 USER=azureuser KEY=~/.ssh/id_ed25519"; exit 1; fi
	bash scripts/deploy.sh $(HOST) $(USER) $(or $(KEY),$(HOME)/.ssh/id_ed25519)

smoke: ## Run the smoke test against a deployed endpoint. Usage: make smoke HOST=x
	@if [ -z "$(HOST)" ]; then echo "Usage: make smoke HOST=20.127.242.99"; exit 1; fi
	bash scripts/smoke_test.sh $(HOST)

clean: ## Remove caches, build artefacts, and the virtualenv.
	rm -rf .pytest_cache __pycache__ tests/__pycache__ artifacts
	rm -rf $(VENV)

clean-all: clean ## Also remove coverage reports and egg-info.
	rm -rf .coverage htmlcov coverage.xml *.egg-info build dist
