# Test and static-analysis targets.
#
# The Go and UI layers of docs/TESTING.md, each with two coverage gates: a
# per-package (or per-path) floor that stops old code regressing, and a
# changed-lines minimum that makes new code arrive with tests.
#
# Every gate here fails the build. None are advisory.

COVERAGE_MIN     ?= 80
CHANGED_MIN      ?= 85
COVERAGE_PROFILE := coverage.out
UI_DIR           := ui

# Repo-wide shell tests, shellcheck and the portability gate, plus gofmt over
# the whole tree, live in the root Makefile (make/shell.mk): they must scan
# scripts outside this module (bootstrap/, platform/, runtimes/). The targets
# here are the Go and UI gates that belong to this self-contained module.

.PHONY: test test-go test-api test-ui test-e2e \
        test-coverage coverage-check changed-lines-go changed-lines-ui \
        golden-update fuzz lint lint-go lint-ui sec vuln validate-content \
        time-budget flake-hunt

## test: Go unit + contract tests with the race detector and coverage gate
test: test-go

## validate-content: schema + cross-reference + template checks over all content
validate-content:
	@echo "==> Validating declarative content (labctl validate)"
	@go run ./cmd/labctl validate

## test-go: Go unit + contract tests, race detector on, both coverage gates
test-go:
	@echo "==> Go tests (race detector, shuffled, coverage gates)"
	@go test -race -shuffle=on -coverprofile=$(COVERAGE_PROFILE) -covermode=atomic ./...
	@$(MAKE) --no-print-directory coverage-check changed-lines-go

## test-api: the HTTP contract suite only (a subset of test-go)
test-api:
	@go test -race ./internal/httpapi/... ./internal/cli/...

## time-budget: every Go test finishes within TIME_BUDGET seconds (default 5), one package at a time
time-budget:
	@echo "==> Go test time per test (budget $(or $(TIME_BUDGET),5)s)"
	@go test -v -p 1 -count=1 ./... > test-time.log 2>&1; status=$$?; grep -E '^(ok|FAIL|---)' test-time.log; \
	  [ $$status -eq 0 ] || exit $$status; \
	  bash scripts/time-budget.sh test-time.log

## flake-hunt: run the Go tests three times in shuffled order; a test that fails once is flaky
flake-hunt:
	@echo "==> Go tests x3, shuffled (flake hunt)"
	@go test -race -count=3 -shuffle=on ./...

## golden-update: rewrite the API and CLI golden files after an intended change
golden-update:
	@go test ./internal/httpapi/ -run 'TestContract_(Success|IndexIsCurrent)' -update
	@go test ./internal/cli/ -update
	@echo "Golden files rewritten under internal/httpapi/testdata/contract and internal/cli/testdata/golden - review the diff before committing."

## coverage-check: per-package gate with a ratchet (.coverage-exceptions)
coverage-check:
	@COVERAGE_PROFILE=$(COVERAGE_PROFILE) COVERAGE_MIN=$(COVERAGE_MIN) \
	  bash scripts/coverage-gate.sh

## changed-lines-go: >= CHANGED_MIN% of the Go lines this change touches are tested
changed-lines-go:
	@CHANGED_MIN=$(CHANGED_MIN) bash scripts/changed-lines-gate.sh go $(COVERAGE_PROFILE)

## changed-lines-ui: the same gate for UI source, from the vitest lcov report
changed-lines-ui:
	@CHANGED_MIN=$(CHANGED_MIN) bash scripts/changed-lines-gate.sh lcov $(UI_DIR)/coverage/lcov.info

## test-coverage: HTML coverage report at coverage.html
test-coverage:
	@go test -coverprofile=$(COVERAGE_PROFILE) -covermode=atomic ./...
	@go tool cover -html=$(COVERAGE_PROFILE) -o coverage.html
	@echo "Coverage report: coverage.html"

## test-ui: vitest component tests with both coverage gates
test-ui:
	@cd $(UI_DIR) && npm run test:coverage
	@$(MAKE) --no-print-directory changed-lines-ui

## test-e2e: playwright journeys against the built SPA
test-e2e:
	@cd $(UI_DIR) && npm run test:e2e

## fuzz: short fuzz run over every fuzz target
fuzz:
	@FUZZTIME="$(FUZZTIME)" sh scripts/fuzz.sh

## lint: the Go and UI static-analysis gates for this module. The repo-wide
## shell gate (lint-shell) and gofmt sweep (fmt-check) run from the root
## Makefile; the aggregate `make lint` there adds them.
lint: lint-go lint-ui sec vuln

lint-go:
	@command -v golangci-lint >/dev/null 2>&1 || { \
	  echo "golangci-lint not found: https://golangci-lint.run/welcome/install/"; exit 1; }
	@golangci-lint run ./...

lint-ui:
	@cd $(UI_DIR) && npm run typecheck && npm run lint

# gosec runs through golangci-lint so there is exactly one gosec policy: the
# rule exclusions and their reasons in .golangci.yml, plus the per-site
# //nolint:gosec justifications. A bare `gosec ./...` reads neither, and
# re-reports every finding this project has already answered.
sec:
	@command -v golangci-lint >/dev/null 2>&1 || { \
	  echo "golangci-lint not found: https://golangci-lint.run/welcome/install/"; exit 1; }
	@golangci-lint run --enable-only=gosec ./...

vuln:
	@command -v govulncheck >/dev/null 2>&1 || { \
	  echo "govulncheck not found: go install golang.org/x/vuln/cmd/govulncheck@latest"; exit 1; }
	@govulncheck ./...
