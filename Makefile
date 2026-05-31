.PHONY: contrib install-hooks generate format lint-format test build clean where install run

SWIFT_FORMAT_PATHS = App Packages
YEAR ?= 2026
# Extra args appended to the xcodebuild line. CI sets this to disable signing
# (CODE_SIGNING_ALLOWED=NO) since the runner has no Developer ID certs.
XCODEBUILD_FLAGS ?=

PROJECT = AmazonOrderExport.xcodeproj
SCHEME = AmazonOrderExport
CONFIG = Debug
# Fixed build location so the .app/binary paths are static (no awk needed).
DERIVED = .build-xcode
APP = $(DERIVED)/Build/Products/$(CONFIG)/AmazonOrderExport.app
BIN = $(APP)/Contents/MacOS/AmazonOrderExport

# Where `make install` puts the app. /Applications is a stable, LaunchServices-
# registered location (override e.g. INSTALL_DIR=~/Applications if needed).
INSTALL_DIR ?= /Applications
INSTALLED = $(INSTALL_DIR)/Amazon Order Export.app
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

contrib:
	@echo "Installing development dependencies..."
	brew install xcodegen
	@$(MAKE) install-hooks
	@$(MAKE) generate

install-hooks:
	@git config core.hooksPath .githooks
	@echo "Configured git hooks to use .githooks/"

generate:
	scripts/embed-build-info.sh
	xcodegen generate

format:
	swift-format format --in-place --recursive --configuration .swift-format $(SWIFT_FORMAT_PATHS)

lint-format:
	swift-format lint --strict --recursive --configuration .swift-format $(SWIFT_FORMAT_PATHS)

test:
	swift test --package-path Packages/AmazonAuth
	swift test --package-path Packages/AmazonOrders
	swift test --package-path Packages/TelemetryScrub

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) $(XCODEBUILD_FLAGS) build

# Delete build artifacts. Leaves the generated .xcodeproj (cheap to regenerate).
clean:
	rm -rf $(DERIVED)

# Print the built binary's path.
where:
	@echo $(BIN)

# Build and install into INSTALL_DIR, registering with LaunchServices so the
# icon shows in the Dock and Cmd-Tab switcher (a transient DerivedData bundle
# often shows a generic icon). Quits any running instance first for a clean swap.
install: build
	@killall AmazonOrderExport >/dev/null 2>&1 || true
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	-"$(LSREGISTER)" -f "$(INSTALLED)"
	@echo "Installed → $(INSTALLED)"

# Build, install, and launch.
run: install
	open "$(INSTALLED)"
