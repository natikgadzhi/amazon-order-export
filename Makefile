.PHONY: contrib install-hooks generate format lint-format test

SWIFT_FORMAT_PATHS = App Packages

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
