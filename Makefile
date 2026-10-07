# SpaceKit developer tasks. Run `make help` for a list.

PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SHAREDIR := $(PREFIX)/share/spacekit
SWIFT ?= swift

.PHONY: help build release test app run tui install uninstall lint format validate-rules clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Debug build of everything
	$(SWIFT) build

release: ## Optimised build of the CLI and app
	$(SWIFT) build -c release

test: ## Run the test suite (includes the safety guarantees)
	$(SWIFT) test

app: ## Build build/SpaceKit.app (release, ad-hoc signed)
	scripts/build-app.sh

run: ## Run the app from source
	$(SWIFT) run SpaceKitApp

tui: ## Run the terminal UI from source on your home folder
	$(SWIFT) run spacekit tui ~

install: release ## Install the CLI to $(BINDIR) and the rule library to $(SHAREDIR)
	@mkdir -p "$(BINDIR)" "$(SHAREDIR)"
	install -m 755 "$$($(SWIFT) build -c release --show-bin-path)/spacekit" "$(BINDIR)/spacekit"
	rm -rf "$(SHAREDIR)/rules" && cp -R rules "$(SHAREDIR)/rules"
	@echo "Installed $(BINDIR)/spacekit. Make sure $(BINDIR) is on your PATH, then try: spacekit doctor"

uninstall: ## Stop the background agent, remove the installed CLI and rules (your config and history stay)
	@if [ -x "$(BINDIR)/spacekit" ]; then "$(BINDIR)/spacekit" agent uninstall || true; fi
	rm -f "$(BINDIR)/spacekit"
	rm -rf "$(SHAREDIR)"

validate-rules: build ## Validate every rule file
	$(SWIFT) run spacekit rules validate

lint: ## Check formatting with swift-format
	swift-format lint --recursive --strict Sources Tests

format: ## Format sources with swift-format
	swift-format format --recursive --in-place Sources Tests

clean: ## Remove build products
	rm -rf .build build
