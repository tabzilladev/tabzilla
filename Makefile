.PHONY: build debug test install uninstall register clean distclean run stop status reload test-url help

APP_NAME := Tabzilla
BUNDLE_ID := dev.tabzilla.Tabzilla
INSTALL_DIR := /Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister
# Xcode puts build output in DerivedData by default
DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData
XCODE_BUILD_APP = $(shell find "$(DERIVED_DATA)" -path "*/Tabzilla-*/Build/Products/Release/Tabzilla.app" -type d 2>/dev/null | head -1)

# Default target
all: build

# Build release app bundle with Xcode
build:
	@echo "Building $(APP_NAME)..."
	@xcodebuild -project $(APP_NAME).xcodeproj \
		-scheme $(APP_NAME) \
		-configuration Release \
		-quiet
	@echo "Build complete"

# Build debug version with SPM (faster iteration)
debug:
	@swift build

# Run unit tests
test:
	@swift test

# Install to /Applications and register with Launch Services
install: build
	@echo "Installing to $(INSTALL_DIR)..."
	@rm -rf "$(INSTALLED_APP)"
	@cp -r "$(XCODE_BUILD_APP)" "$(INSTALL_DIR)/"
	@$(LSREGISTER) -f "$(INSTALLED_APP)"
	@echo "Installed and registered $(APP_NAME)"

# Uninstall from /Applications
uninstall:
	@echo "Uninstalling $(APP_NAME)..."
	@rm -rf "$(INSTALLED_APP)"
	@echo "Uninstalled"

# Re-register with Launch Services (useful after manual copy)
register:
	@$(LSREGISTER) -f "$(INSTALLED_APP)"
	@echo "Registered $(APP_NAME) with Launch Services"

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@rm -rf .build
	@xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) clean -quiet 2>/dev/null || true
	@echo "Clean complete"

# Deep clean (also removes Xcode derived data - requires re-fetching packages)
distclean: clean
	@echo "Deep cleaning..."
	@rm -rf "$(DERIVED_DATA)"/$(APP_NAME)-*
	@echo "Deep clean complete"

# Run the installed app (daemon mode)
run:
	@open "$(INSTALLED_APP)"

# Stop the daemon
stop:
	@"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" quit 2>/dev/null || echo "Daemon not running"

# Show daemon status
status:
	@"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" status

# Reload configuration
reload:
	@"$(INSTALLED_APP)/Contents/MacOS/$(APP_NAME)" reload

# Test a URL (uses debug build for faster iteration)
test-url: debug
	@test -n "$(URL)" || (echo "Usage: make test-url URL=https://example.com [CONFIG=path/to/config.yaml]" && exit 1)
	@.build/debug/$(APP_NAME) test "$(URL)" $(if $(CONFIG),-c "$(CONFIG)",)

# Show help
help:
	@echo "Tabzilla Development Commands"
	@echo ""
	@echo "  make build      Build release app bundle"
	@echo "  make debug      Build debug binary with SPM (fast)"
	@echo "  make test       Run unit tests"
	@echo "  make install    Build, install to /Applications, register"
	@echo "  make uninstall  Remove from /Applications"
	@echo "  make register   Re-register with Launch Services"
	@echo "  make clean      Remove build artifacts"
	@echo ""
	@echo "  make run        Start the daemon"
	@echo "  make stop       Stop the daemon"
	@echo "  make status     Show daemon status"
	@echo "  make reload     Reload configuration"
	@echo ""
	@echo "  make test-url URL=<url> [CONFIG=<path>]"
	@echo "                  Test which rule matches (uses debug build)"
	@echo ""
	@echo "Examples:"
	@echo "  make install"
	@echo "  make test-url URL=https://github.com/user/repo/pull/123"
	@echo "  make test-url URL=https://example.com CONFIG=test/fixtures/config.yaml"
