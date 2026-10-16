ifneq (,$(wildcard .env))
	include .env
	# Normalise every variable the file defines with $(strip). This keeps any
	# existing .env working, including ones copied from an older, inline-commented
	# .env.example.
$(foreach v,$(shell sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' .env),$(eval $(v) := $(strip $($(v)))))
	export
endif

PROFILE ?= k3d
CLUSTER_NAME ?= snowops
APP_NAME ?= go-api
HELM_RELEASE_NAME ?= go-api
HELM_VALUES ?= values-dev.yaml
# Mirrors src/make/test.mk; used only in the help text below.
COVERAGE_MIN ?= 80

# Defaults are read from .env if present; any command may override them by
# passing VAR=val on the make command line.

include make/vars.mk
include make/bootstrap.mk
include make/runtime.mk
include make/app.mk
include make/platform.mk
include make/check.mk
include make/services.mk
include make/shell.mk
include make/docs.mk
include make/test-gates.mk

SRC_TARGETS := cli-build cli-build-all cli-install cli-clean ui-build ui-deps \
               test-go test-api test-coverage coverage-check fuzz \
               changed-lines-go changed-lines-ui golden-update time-budget flake-hunt \
               lint-go lint-ui sec vuln validate-content \
               test-ui test-e2e

.PHONY: $(SRC_TARGETS)
$(SRC_TARGETS):
	@$(MAKE) --no-print-directory -C src $@ BIN_DIR=$(CURDIR)/bin

.DEFAULT_GOAL := help

.PHONY: help init teardown reset run test test-cluster lint docs-check

# ── Aggregate test & lint (Go module + repo-wide shell gates) ─────────────────

## test: Go unit + contract tests (src/ and apps/), the shell (bats) suites,
## and the check that the change brought tests with it
test: test-go test-apps test-shell test-check

## test-cluster: run one item end to end on the current cluster (ITEM=incident/oom-kill or scenario/env-promotion)
test-cluster:
	@test -n "$(ITEM)" || { echo "usage: make test-cluster ITEM=<scenario|incident>/<name>"; exit 2; }
	@sh src/test/cluster/run.sh "$(firstword $(subst /, ,$(ITEM)))" "$(lastword $(subst /, ,$(ITEM)))"

## test-apps: unit tests for the demo applications (each is its own Go module)
.PHONY: test-apps
test-apps:
	@for mod in $$(find apps -name go.mod -maxdepth 2 | sort); do \
		dir=$$(dirname $$mod); \
		echo "==> app unit tests ($$dir)"; \
		( cd $$dir && go test ./... ) || exit 1; \
	done

## lint: every static-analysis gate - gofmt + shell (root) and Go/UI (src/)
lint: fmt-check lint-shell lint-go lint-ui sec vuln docs-check

# ── Release ──────────────────────────────────────────────────────────────────

## release: open the pull request that releases VERSION=X.Y.Z (RELEASING.md)
.PHONY: release
release:
	@[ -n "$(VERSION)" ] || { echo "usage: make release VERSION=X.Y.Z [NEXT=X.Y.Z-dev]"; exit 2; }
	@sh scripts/release.sh "$(VERSION)" $(NEXT)

# ── Lifecycle ────────────────────────────────────────────────────────────────

init:
	@$(MAKE) setup-tools PROFILE=$(PROFILE)
	@$(MAKE) runtime-up
	@$(MAKE) platform-up

teardown:
	@$(MAKE) destroy-all-apps || true
	@$(MAKE) platform-down || true
	@$(MAKE) runtime-down || true

reset: teardown init

run:
	@$(MAKE) local-run APP_NAME=$(APP_NAME)

## ui: rebuild the UI + binary (fresh embed) and launch the web UI
ui: cli-build
	@./bin/labctl ui

.PHONY: ui ui-dev
ui-dev:
	@LABCTL_UI_DIR=$(CURDIR)/src/ui/dist ./bin/labctl ui

# ── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo "SnowOps Labs - Kubernetes platform-engineering simulator"
	@echo ""
	@echo "  Quick start:"
	@echo "    make cli-build           Build bin/labctl (UI embedded)"
	@echo "    make ui                  Rebuild UI + binary and launch the web UI"
	@echo "    make ui-dev              Launch the web UI serving src/ui/dist live (no Go rebuild)"
	@echo "    make init                setup-tools + runtime-up + platform-up"
	@echo "    make teardown            Remove apps, platform and cluster"
	@echo "    make reset               teardown then init"
	@echo ""
	@echo "  Test & quality (docs/TESTING.md):"
	@echo "    make test                Go + apps + shell tests, coverage gates, test-check"
	@echo "    make test-go             Go unit + contract tests (>= $(COVERAGE_MIN)% per package, changed lines gated)"
	@echo "    make test-apps           unit tests for apps/ (separate Go modules)"
	@echo "    make test-shell          bats suites with kubectl/helm stubbed"
	@echo "    make test-api            HTTP contract suite only"
	@echo "    make test-ui             vitest component tests with coverage gates"
	@echo "    make test-e2e            playwright journeys"
	@echo "    make test-check          a change to code changed a test with it"
	@echo "    make golden-update       rewrite the API contract golden files (review the diff)"
	@echo "    make test-coverage       HTML coverage report -> coverage.html"
	@echo "    make fuzz                short fuzz run over every fuzz target"
	@echo "    make lint                every static-analysis gate"
	@echo "    make fmt                 gofmt the tree"
	@echo ""
	@echo "  Release (maintainer - RELEASING.md):"
	@echo "    make release VERSION=X.Y.Z  Open the release pull request (NEXT=X.Y.Z-dev to override)"
	@echo ""
	@echo "  CLI (labctl):"
	@echo "    make cli-build           Build for the host platform"
	@echo "    make cli-build-all       Cross-compile every release target into dist/"
	@echo "    make cli-install         Build and install onto PATH"
	@echo "    make cli-clean           Remove build outputs"
	@echo ""
	@echo "  Cluster (PROFILE=$(PROFILE) - k3d | kind | incluster):"
	@echo "    make runtime-up          Create cluster '$(CLUSTER_NAME)'"
	@echo "    make runtime-down        Destroy the current cluster"
	@echo "    make runtime-status      Show cluster info and nodes"
	@echo "    make check-tools         Verify required binaries are on PATH"
	@echo "    make check-cluster       Ensure the current context reaches the cluster"
	@echo "    make check-ingress       Confirm the ingress controller is ready"
	@echo ""
	@echo "  Platform components:"
	@echo "    make platform-up         Install the configured providers"
	@echo "    make platform-down       Remove them"
	@echo "    make platform-status     Show provider status"
	@echo "    Provider variables (set in .env or on the command line):"
	@echo "      INGRESS_PROVIDER=traefik|nginx          (default: traefik)"
	@echo "      METRICS_PROVIDER=prometheus             (default: prometheus)"
	@echo "      LOGGING_PROVIDER=loki                   (unset = disabled)"
	@echo "      TRACING_PROVIDER=tempo                  (unset = disabled)"
	@echo ""
	@echo "  Applications:"
	@echo "    make build APP_NAME=<name>       Run the app's build strategy"
	@echo "    make run APP_NAME=<name>         Run it locally"
	@echo "    make deploy APP_NAME=<name>      Run its deploy strategy"
	@echo "    make destroy-app APP_NAME=<name> Remove it"
	@echo "    make deploy-all / destroy-all-apps"
	@echo ""
	@echo "  Shared services:"
	@echo "    make service-list                List available services"
	@echo "    make service-up SERVICE=<name>   Install one (e.g. redis)"
	@echo "    make service-down SERVICE=<name> Uninstall one"
	@echo "    make service-status              Show status"
	@echo ""
	@echo "Per-app configuration lives in apps/<name>/app.env (BUILD_STRATEGY,"
	@echo "DEPLOY_STRATEGY, HELM_VALUES). Override on the command line:"
	@echo "  make build APP_NAME=foo BUILD_STRATEGY=golang"
