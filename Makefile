SHELL := /bin/bash
APP_NAME := Tabzilla
BUNDLE_ID := dev.tabzilla.Tabzilla
INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
# Xcode puts build output in DerivedData by default
DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData
XCODE_BUILD_APP = $(shell find "$(DERIVED_DATA)" -path "*/Tabzilla-*/Build/Products/Release/Tabzilla.app" -type d 2>/dev/null | head -1)
XCODE_DEBUG_APP = $(shell find "$(DERIVED_DATA)" -path "*/Tabzilla-*/Build/Products/Debug/Tabzilla.app" -type d 2>/dev/null | head -1)
REPO_URL = $(shell gh repo view --json url -q .url)

.DEFAULT_GOAL := all

# lint and format-check run last so they don't block build/test during iteration on in-progress code
.PHONY: all
all: test build lint format-check ## Runs default targets: test, build, lint, format-check

# Self-documenting Makefile inspired by: https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

# Dependencies

# Checks everything needed to build, test, lint, and format.
# Add tool dependencies to the list in the loop below, with hints for how to install.
.build/build-tools.stamp:
	@echo "Checking build tools..."
	@ok=1; \
	for entry in \
		"xcodebuild:install Xcode from the App Store" \
		"xcrun:install Xcode from the App Store" \
		"swift:install Xcode from the App Store" \
		"swiftlint:brew install swiftlint" \
		"swiftformat:brew install swiftformat" \
	; do \
		tool=$${entry%%:*}; hint=$${entry#*:}; \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "ok: $$tool"; \
		else \
			echo "missing: $$tool — $$hint"; \
			ok=0; \
		fi; \
	done; \
	test $$ok -eq 1 || { echo "Install missing tools and re-run."; exit 1; }
	@mkdir -p .build
	@touch $@

# Checks everything needed to cut a release.
# Add tool dependencies to the list in the loop below, with hints for how to install.
.build/release-tools.stamp:
	@echo "Checking release tools..."
	@ok=1; \
	for entry in \
		"gh:brew install gh" \
	; do \
		tool=$${entry%%:*}; hint=$${entry#*:}; \
		if command -v $$tool >/dev/null 2>&1; then \
			echo "ok: $$tool"; \
		else \
			echo "missing: $$tool — $$hint"; \
			ok=0; \
		fi; \
	done; \
	test $$ok -eq 1 || { echo "Install missing tools and re-run."; exit 1; }
	@mkdir -p .build
	@touch $@

.PHONY: build-tools
build-tools: .build/build-tools.stamp ## Check build/test/lint/format tool dependencies

.PHONY: release-tools
release-tools: .build/release-tools.stamp ## Check release tool dependencies

##@ Build

# xcodebuild buils use a dynamic directory for build products, so we use stamp
# files to track when a build is needed.
XCODEPROJ_SOURCES := $(shell find $(APP_NAME).xcodeproj -type f 2>/dev/null)
APP_SOURCES       := $(shell find Sources -type f 2>/dev/null)
TEST_SOURCES      := $(shell find Tests -type f 2>/dev/null)

.build/release.stamp: .build/build-tools.stamp $(XCODEPROJ_SOURCES) $(APP_SOURCES)
	@echo "Building $(APP_NAME)..."
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
	@mkdir -p .build
	@touch $@
	@echo "Release build complete: $(XCODE_BUILD_APP)"

.build/debug.stamp: .build/build-tools.stamp $(XCODEPROJ_SOURCES) $(APP_SOURCES)
	@echo "Building $(APP_NAME) (debug)..."
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Debug \
		-destination 'platform=macOS,arch=$(shell uname -m)'
	@mkdir -p .build
	@touch $@
	@echo "Debug build complete: $(XCODE_DEBUG_APP)"

.build/test.stamp: .build/build-tools.stamp $(APP_SOURCES) $(TEST_SOURCES)
	@swift test
	@mkdir -p .build
	@touch $@

.PHONY: build
build: .build/release.stamp ## Build universal release app bundle (arm64 + x86_64)

# Build debug app bundle (used as prerequisite by test-url)
.PHONY: debug
debug: .build/debug.stamp ## Build debug app bundle for current arch only (see: uname -m)

.PHONY: test
test: .build/test.stamp ## Run unit tests via SPM

.PHONY: test-url
test-url: debug ## Test which rule matches a URL; usage: make test-url URL=https://example.com [CONFIG=path]
	@test -n "$(URL)" || (echo "Usage: make test-url URL=https://example.com [CONFIG=path/to/config.yaml]" && exit 1)
	@"$(XCODE_DEBUG_APP)/Contents/MacOS/$(APP_NAME)" test "$(URL)" $(if $(CONFIG),-c "$(CONFIG)",)

.PHONY: clean
clean: ## Remove build artifacts
	@echo "Cleaning..."
	@rm -rf .build
	@xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) clean -quiet 2>/dev/null || true
	@echo "Clean complete"

.PHONY: distclean
distclean: clean ## Deep clean: also removes Xcode DerivedData (requires re-fetching packages)
	@echo "Deep cleaning..."
	@rm -rf "$(DERIVED_DATA)"/$(APP_NAME)-*
	@echo "Deep clean complete"

##@ Lint & Format

SWIFT_SOURCES := Sources Tests
OBJC_M_SOURCES := $(shell find Sources -name '*.m')
OBJC_H_SOURCES := $(shell find Sources -name '*.h' | grep -v Chrome.h)

.build/lint.log: .build/build-tools.stamp $(APP_SOURCES) $(TEST_SOURCES)
	@mkdir -p .build
	@{ swiftlint lint 2>&1; } | tee $@ ; test $${PIPESTATUS[0]} -eq 0
	@echo "swiftlint: no issues"
	@{ xcrun clang-format --dry-run --Werror $(OBJC_M_SOURCES) 2>&1; } | tee -a $@ ; test $${PIPESTATUS[0]} -eq 0
	@for f in $(OBJC_H_SOURCES); do { xcrun clang-format --dry-run --Werror --assume-filename=x.m < "$$f" 2>&1; } | tee -a $@ ; test $${PIPESTATUS[0]} -eq 0 || exit 1; done
	@echo "clang-format: no issues"

.PHONY: lint
lint: .build/lint.log ## Lint Swift (swiftlint) and Objective-C (clang-format --dry-run)

.build/format-check.log: .build/build-tools.stamp $(APP_SOURCES) $(TEST_SOURCES)
	@mkdir -p .build
	@{ swiftformat $(SWIFT_SOURCES) --lint 2>&1; } | tee $@ ; test $${PIPESTATUS[0]} -eq 0
	@{ xcrun clang-format --dry-run --Werror $(OBJC_M_SOURCES) 2>&1; } | tee -a $@ ; test $${PIPESTATUS[0]} -eq 0
	@for f in $(OBJC_H_SOURCES); do { xcrun clang-format --dry-run --Werror --assume-filename=x.m < "$$f" 2>&1; } | tee -a $@ ; test $${PIPESTATUS[0]} -eq 0 || exit 1; done

.PHONY: format-check
format-check: .build/format-check.log ## Check formatting without making changes

.PHONY: format
format: .build/build-tools.stamp ## Format Swift (swiftformat) and Objective-C (clang-format -i)
	@swiftformat $(SWIFT_SOURCES)
	@xcrun clang-format -i $(OBJC_M_SOURCES)
	@for f in $(OBJC_H_SOURCES); do xcrun clang-format --assume-filename=x.m < "$$f" > "$$f.tmp" && mv "$$f.tmp" "$$f"; done

##@ Install

.PHONY: install
install: build ## Build, install to /Applications, and register with Launch Services
	@echo "Installing to $(INSTALL_DIR)..."
	@rm -rf "$(INSTALLED_APP)"
	@cp -r "$(XCODE_BUILD_APP)" "$(INSTALL_DIR)/"
	@$(LSREGISTER) -f "$(INSTALLED_APP)"
	@echo "Installed and registered $(APP_NAME)"

# Removes the app AND the macOS state that otherwise survives outside the app bundle
# (keyed by bundle id) and silently "reappears" on reinstall:
#   - LaunchServices: the default http/https handler choice (the "default browser"
#     setting) plus Tabzilla's URL-scheme capability registration. The app bundle is
#     removed first, then a full `-kill -r` rebuild drops the stale Tabzilla bindings;
#     macOS then self-heals the default handler back to another installed browser.
#     (A plain `lsregister -u` does NOT clear the persisted choice — the rebuild does.)
#   - TCC: Accessibility + Automation (AppleEvents) grants.
# The running daemon is killed FIRST — otherwise `rm -rf` orphans a daemon still
# running from the deleted bundle, and a live process keeps the requirement
# checks reading as satisfied. All matching processes are killed (e.g. an extra
# instance launched from DerivedData), not just the installed one.
# Leaves config files untouched. Gatekeeper note: the "Open Anyway" approval is keyed to
# code identity and is not cleanly resettable here; a fresh `brew install` re-quarantines
# and re-triggers it. (`make install` does its own bundle removal, so the fast dev
# reinstall loop never needs this — use it when you want a true fresh-install state.)
# TCC caveat: this app is adhoc-signed (no stable signing identity), so a
# `tccutil reset <bundle-id>` often matches nothing and the grant survives.
# `tccutil reset` exits 0 regardless, so we can't detect this — re-run `tabz doctor`
# after, and if a grant persists, remove Tabzilla manually in System Settings ›
# Privacy & Security › Accessibility / Automation.
.PHONY: uninstall
uninstall: ## Remove app + clear macOS default-browser/TCC state (fresh-install reset)
	@echo "Uninstalling $(APP_NAME)..."
	@if pgrep -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1; then \
		pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"; \
		sleep 1; \
		echo "  ✓ stopped running daemon(s)"; \
	else \
		echo "  - daemon not running"; \
	fi
	@rm -rf "$(INSTALLED_APP)"
	@$(LSREGISTER) -kill -r -domain local -domain user -domain system >/dev/null 2>&1 || true
	@echo "  ✓ removed app and rebuilt Launch Services (stale default-browser binding dropped)"
	@tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true; echo "  ↻ requested Accessibility reset"
	@tccutil reset AppleEvents $(BUNDLE_ID) >/dev/null 2>&1 || true; echo "  ↻ requested Automation (AppleEvents) reset"
	@echo "Uninstalled — app removed, default browser cleared, TCC resets requested."
	@echo "Note: TCC resets may not clear adhoc-signed grants — verify with 'tabz doctor'."
	@echo "Note: Gatekeeper approval is not reset here — a fresh 'brew install' re-triggers it."

.PHONY: register
register: ## Re-register with Launch Services (useful after manual copy)
	@$(LSREGISTER) -f "$(INSTALLED_APP)"
	@echo "Registered $(APP_NAME) with Launch Services"

##@ Release

.PHONY: show-version
show-version: ## Show current version
	@grep -o 'appVersion = "[^"]*"' Sources/CLI.swift | grep -o '"[^"]*"' | tr -d '"'

.PHONY: set-version
set-version: ## Set version across all source files; usage: make set-version V=X.Y.Z
	@test -n "$(V)" || (echo "Usage: make set-version V=X.Y.Z" && exit 1)
	@scripts/set-version.sh "$(V)"

.PHONY: package
package: build ## Zip release app bundle and print SHA256; usage: make package V=X.Y.Z
	@test -n "$(V)" || (echo "Usage: make package V=X.Y.Z" && exit 1)
	@test -d "$(XCODE_BUILD_APP)" || (echo "Error: release app not found — run 'make build' first"; exit 1)
	@mkdir -p build
	@ZIP_NAME="$(APP_NAME)-$(V)-macos.zip"; \
	ZIP_PATH="$$(pwd)/build/$$ZIP_NAME"; \
	APP_DIR="$$(dirname "$(XCODE_BUILD_APP)")"; \
	APP_NAME_ONLY="$$(basename "$(XCODE_BUILD_APP)")"; \
	rm -f "$$ZIP_PATH"; \
	(cd "$$APP_DIR" && zip -r -y "$$ZIP_PATH" "$$APP_NAME_ONLY" > /dev/null); \
	SHA256=$$(shasum -a 256 "$$ZIP_PATH" | awk '{print $$1}'); \
	echo "zip=build/$$ZIP_NAME"; \
	echo "sha256=$$SHA256"

.PHONY: ci-trigger
ci-trigger: .build/release-tools.stamp ## Trigger CI workflow and watch; usage: make ci-trigger [NOWATCH=1]
	@gh workflow run ci
	@sleep 3
	@RUN_ID=$$(gh run list --workflow=ci --limit=1 --json databaseId -q '.[0].databaseId'); \
	echo "CI run: $(REPO_URL)/actions/runs/$$RUN_ID"; \
	$(if $(filter 1,$(NOWATCH)),true,gh run watch "$$RUN_ID" --exit-status)

.PHONY: ci-status
ci-status: .build/release-tools.stamp ## Show recent CI runs for the current branch
	@gh run list --branch "$$(git rev-parse --abbrev-ref HEAD)" --limit 5
	@echo "View on GitHub: $(REPO_URL)/actions"

.PHONY: ci-watch
ci-watch: .build/release-tools.stamp ## Watch a CI run until it completes; defaults to the current HEAD commit, override with RUN=<id>
	@RUN_ID="$(RUN)"; \
	if [ -z "$$RUN_ID" ]; then \
		SHA=$$(git rev-parse HEAD); \
		echo "Waiting for CI run at $$SHA..."; \
		for i in $$(seq 1 30); do \
			RUN_ID=$$(gh run list --limit=20 --json databaseId,headSha -q "[.[] | select(.headSha == \"$$SHA\")] | .[0].databaseId // empty"); \
			[ -n "$$RUN_ID" ] && break; \
			sleep 2; \
		done; \
		if [ -z "$$RUN_ID" ]; then \
			echo "Error: no CI run found for $$SHA after 60s" >&2; \
			exit 1; \
		fi; \
	fi; \
	echo "CI run: $(REPO_URL)/actions/runs/$$RUN_ID"; \
	gh run watch "$$RUN_ID" --exit-status

.PHONY: release
release: .build/release-tools.stamp ## Bump, tag, push, and watch CI; usage: make release V=X.Y.Z [DRY_RUN=1] [FORCE=1] [NOWATCH=1]
	@test -n "$(V)" || (echo "Usage: make release V=X.Y.Z [DRY_RUN=1] [FORCE=1] [NOWATCH=1]" && exit 1)
	@scripts/release.sh "$(V)" $(if $(filter 1,$(DRY_RUN)),--dry-run,) $(if $(filter 1,$(FORCE)),--force,)
	$(if $(filter 1,$(DRY_RUN)),,$(if $(filter 1,$(NOWATCH)),,@$(MAKE) ci-watch))

.PHONY: release-status
release-status: .build/release-tools.stamp ## Show the latest GitHub release
	@gh release view

##@ Daemon

.PHONY: start
start: ## Start the installed app (daemon mode)
	@open --hide "$(INSTALLED_APP)"

.PHONY: stop
stop: ## Stop the daemon gracefully
	@"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" stop 2>/dev/null || echo "Daemon not running"
	@sleep 1
	@if pgrep -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1; then \
		echo "Error: Tabzilla process(es) still running (possibly launched from Xcode or DerivedData)"; \
		echo "Run 'make kill' to terminate all Tabzilla processes"; \
		exit 1; \
	fi

.PHONY: kill
kill: ## Force kill all Tabzilla processes
	@if pgrep -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" >/dev/null 2>&1; then \
		pkill -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)"; \
		echo "Killed all Tabzilla processes"; \
	else \
		echo "No Tabzilla processes running"; \
	fi

.PHONY: status
status: ## Show daemon status
	@"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" status

.PHONY: dump
dump: ## Dump full state as JSON (for tools/agents)
	@"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" dump

.PHONY: reload
reload: ## Reload configuration
	@"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" reload

# LOG_LEVEL: info (default) or debug
# LAST: time duration, e.g. 1h, 30m (default: 1d, log show only)
LOG_LEVEL ?= info
LAST ?= 1d

.PHONY: logs
logs: ## Show recent logs; LOG_LEVEL=info|debug, LAST=1d
	$(eval _LOG_FLAGS := $(if $(filter debug,$(LOG_LEVEL)),--info --debug,--info))
	$(eval _LOG_CMD := log show --predicate 'subsystem == "$(BUNDLE_ID)"' $(_LOG_FLAGS) --last $(LAST))
	@echo "$(_LOG_CMD)" >&2
	@$(_LOG_CMD)

.PHONY: logs-follow
logs-follow: ## Stream logs; LOG_LEVEL=info|debug
	$(eval _LOG_CMD := log stream --predicate 'subsystem == "$(BUNDLE_ID)"' --level $(LOG_LEVEL))
	@echo "$(_LOG_CMD)" >&2
	@$(_LOG_CMD)
