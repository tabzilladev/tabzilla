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

# Default target
all: build

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Build

.PHONY: build
build: ## Build release app bundle with Xcode
	@echo "Building $(APP_NAME)..."
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		-quiet
	@echo "Build complete"

# Build debug app bundle (used as prerequisite by test-url)
.PHONY: debug
debug:
	@echo "Building $(APP_NAME) (debug)..."
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Debug \
		-quiet
	@echo "Debug build complete"

.PHONY: test
test: ## Run unit tests via SPM
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

.PHONY: version
version: ## Show current version
	@grep -o 'version: "[^"]*"' Sources/CLI.swift | grep -o '"[^"]*"' | tr -d '"'

.PHONY: set-version
set-version: ## Set version across all source files; usage: make set-version V=X.Y.Z
	@test -n "$(V)" || (echo "Usage: make set-version V=X.Y.Z" && exit 1)
	@scripts/set-version.sh "$(V)"

.PHONY: release
release: ## Tag and push current version to trigger CI release; use FORCE=1 to re-tag an existing version
	@scripts/release.sh $(if $(filter 1,$(FORCE)),--force,)

.PHONY: release-status
release-status: ## Show the latest GitHub release
	@gh release view

.PHONY: ci-status
ci-status: ## Show recent CI runs for the current branch
	@gh run list --branch "$$(git rev-parse --abbrev-ref HEAD)" --limit 5
	@echo "View on GitHub: $(REPO_URL)/actions"

.PHONY: ci-watch
ci-watch: ## Watch the most recent CI run until it completes
	@gh run watch --exit-status
	@echo "View on GitHub: $(REPO_URL)/actions"

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
