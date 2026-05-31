.PHONY: contrib install-hooks generate format lint-format test build authenticate check

SWIFT_FORMAT_PATHS = App Packages

PROJECT = AmazonOrderExport.xcodeproj
SCHEME = AmazonOrderExport
CONFIG = Debug
# Fixed build location so the .app/binary paths are static (no awk needed).
DERIVED = .build-xcode
APP = $(DERIVED)/Build/Products/$(CONFIG)/AmazonOrderExport.app
BIN = $(APP)/Contents/MacOS/AmazonOrderExport

contrib:
	@echo "Installing development dependencies..."
	brew install xcodegen
	@$(MAKE) install-hooks
	@$(MAKE) generate

install-hooks:
	@git config core.hooksPath .githooks
	@echo "Configured git hooks to use .githooks/"

generate:
	xcodegen generate

format:
	swift-format format --in-place --recursive --configuration .swift-format $(SWIFT_FORMAT_PATHS)

lint-format:
	swift-format lint --strict --recursive --configuration .swift-format $(SWIFT_FORMAT_PATHS)

test:
	swift test --package-path Packages/AmazonAuth
	swift test --package-path Packages/AmazonOrders

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build

# Interactive Amazon login. Equivalent to running the app in Xcode (⌘R), which
# is the most reliable way to see the login page + console logs.
authenticate: build
	open -n -W $(APP) --args authenticate

# Headless session check (plain HTTP, no GUI). Leading '-' so a non-zero status
# (expired/no-session) just prints its message instead of make's error noise.
check: build
	-$(BIN) check
