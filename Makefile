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

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

# Dependencies

.PHONY: require-xcodebuild
require-xcodebuild:
	@command -v xcodebuild >/dev/null 2>&1 || \
		{ echo "missing: xcodebuild — install Xcode from the App Store"; exit 1; }

.PHONY: require-xcrun
require-xcrun:
	@command -v xcrun >/dev/null 2>&1 || \
		{ echo "missing: xcrun — install Xcode from the App Store"; exit 1; }

.PHONY: require-swift
require-swift:
	@command -v swift >/dev/null 2>&1 || \
		{ echo "missing: swift — install Xcode from the App Store"; exit 1; }

.PHONY: require-swiftlint
require-swiftlint:
	@command -v swiftlint >/dev/null 2>&1 || \
		{ echo "missing: swiftlint — brew install swiftlint"; exit 1; }

.PHONY: require-swiftformat
require-swiftformat:
	@command -v swiftformat >/dev/null 2>&1 || \
		{ echo "missing: swiftformat — brew install swiftformat"; exit 1; }

.PHONY: require-gh
require-gh:
	@command -v gh >/dev/null 2>&1 || \
		{ echo "missing: gh — brew install gh"; exit 1; }

##@ Build

.PHONY: build
build: require-xcodebuild ## Build universal release app bundle (arm64 + x86_64)
	@echo "Building $(APP_NAME)..."
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
		-quiet
	@echo "Release build complete: $(XCODE_BUILD_APP)"

# Build debug app bundle (used as prerequisite by test-url)
.PHONY: debug
debug: require-xcodebuild ## Build debug app bundle for current arch only (see: uname -m)
	@echo "Building $(APP_NAME) (debug)..."
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Debug \
		-destination 'platform=macOS,arch=$(shell uname -m)' \
		-quiet
	@echo "Debug build complete: $(XCODE_DEBUG_APP)"

.PHONY: test
test: require-swift ## Run unit tests via SPM
	@swift test

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

.PHONY: lint
lint: require-swiftlint require-xcrun ## Lint Swift (swiftlint) and Objective-C (clang-format --dry-run)
	@swiftlint lint --quiet
	@echo "swiftlint lint: no issues"
	@xcrun clang-format --dry-run --Werror $(OBJC_M_SOURCES)
	@for f in $(OBJC_H_SOURCES); do xcrun clang-format --dry-run --Werror --assume-filename=x.m < "$$f" > /dev/null || exit 1; done
	@echo "clang-format: no issues"

.PHONY: format-check
format-check: require-swiftformat require-xcrun ## Check formatting without making changes
	@swiftformat $(SWIFT_SOURCES) --lint
	@xcrun clang-format --dry-run --Werror $(OBJC_M_SOURCES)
	@for f in $(OBJC_H_SOURCES); do xcrun clang-format --dry-run --Werror --assume-filename=x.m < "$$f" > /dev/null || exit 1; done

.PHONY: format
format: require-swiftformat require-xcrun ## Format Swift (swiftformat) and Objective-C (clang-format -i)
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

.PHONY: uninstall
uninstall: ## Remove from /Applications
	@echo "Uninstalling $(APP_NAME)..."
	@rm -rf "$(INSTALLED_APP)"
	@echo "Uninstalled"

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
	zip -r -y "build/$$ZIP_NAME" "$(XCODE_BUILD_APP)" > /dev/null; \
	SHA256=$$(shasum -a 256 "build/$$ZIP_NAME" | awk '{print $$1}'); \
	echo "zip=build/$$ZIP_NAME"; \
	echo "sha256=$$SHA256"

.PHONY: ci-trigger
ci-trigger: require-gh ## Trigger CI workflow and watch; usage: make ci-trigger [NOWATCH=1]
	@gh workflow run ci
	@sleep 3
	@RUN_ID=$$(gh run list --workflow=ci --limit=1 --json databaseId -q '.[0].databaseId'); \
	echo "CI run: $(REPO_URL)/actions/runs/$$RUN_ID"; \
	$(if $(filter 1,$(NOWATCH)),true,gh run watch "$$RUN_ID" --exit-status)

.PHONY: ci-status
ci-status: require-gh ## Show recent CI runs for the current branch
	@gh run list --branch "$$(git rev-parse --abbrev-ref HEAD)" --limit 5
	@echo "View on GitHub: $(REPO_URL)/actions"

.PHONY: ci-watch
ci-watch: require-gh ## Watch the most recent CI run until it completes
	@gh run watch --exit-status
	@echo "View on GitHub: $(REPO_URL)/actions"

.PHONY: release
release: require-gh ## Bump, tag, push, and watch CI; usage: make release V=X.Y.Z [DRY_RUN=1] [FORCE=1] [NOWATCH=1]
	@test -n "$(V)" || (echo "Usage: make release V=X.Y.Z [DRY_RUN=1] [FORCE=1] [NOWATCH=1]" && exit 1)
	@scripts/release.sh "$(V)" $(if $(filter 1,$(DRY_RUN)),--dry-run,) $(if $(filter 1,$(FORCE)),--force,) $(if $(filter 1,$(NOWATCH)),--no-watch,)

.PHONY: release-status
release-status: require-gh ## Show the latest GitHub release
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
