.PHONY: contrib install-hooks generate format lint-format test build authenticate check

SWIFT_FORMAT_PATHS = App Packages

PROJECT = AmazonOrderExport.xcodeproj
SCHEME = AmazonOrderExport
CONFIG = Debug

# Resolve the built binary path from xcodebuild's settings.
BIN_CMD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -showBuildSettings 2>/dev/null | \
	awk -F' = ' '/ BUILT_PRODUCTS_DIR /{a=$$2} / EXECUTABLE_PATH /{b=$$2} END{print a"/"b}'

contrib:
	@echo "Installing development dependencies..."
	brew install xcodegen
	brew install --head xcode-build-server || true
	brew install xcbeautify || true
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
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) build

# Open the login window and store the Amazon session (needs a GUI session).
authenticate: build
	@"$$($(BIN_CMD))" authenticate

# Probe the stored session: prints authenticated / expired / no stored session.
# Leading '-' so a non-zero status (expired/no-session) shows the message
# instead of make's "Error" noise. Call the binary directly if you need the code.
check: build
	-@"$$($(BIN_CMD))" check
