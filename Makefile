.PHONY: help install install-haskell install-ruby build test test-haskell test-ruby run clean db-reset

CONFIG      ?= config/urls.yaml
FORMAT      ?= json
CONCURRENT  ?= 4
RATE        ?= 2.0
DB          ?= web_scraper.sqlite3

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

install: install-haskell install-ruby ## Install both toolchains' dependencies

install-haskell: ## Fetch GHC (auto-repairing a known macOS lld/configure bug) and build Haskell deps
	@if ! command -v stack >/dev/null 2>&1; then \
		echo "error: 'stack' is not installed or not on PATH."; \
		echo "       Install it with: curl -sSL https://get.haskellstack.org/ | sh"; \
		echo "       See README.md's Prerequisites section for details."; \
		exit 1; \
	fi
	bash scripts/install-ghc.sh
	@if [ -f .ghc-system-path ]; then \
		PATH="$$(cat .ghc-system-path):$$PATH" stack build --dependencies-only --system-ghc; \
	else \
		stack build --dependencies-only; \
	fi

install-ruby: ## Install Ruby gems via Bundler
	@ruby_version="$$(ruby -e 'print RUBY_VERSION' 2>/dev/null)"; \
	if [ -z "$$ruby_version" ]; then \
		echo "error: 'ruby' is not installed or not on PATH."; \
		echo "       See README.md's Prerequisites section."; \
		exit 1; \
	fi; \
	major="$$(echo "$$ruby_version" | cut -d. -f1)"; \
	if [ "$$major" -lt 3 ]; then \
		echo "error: found Ruby $$ruby_version on PATH, but this project needs Ruby >= 3.0."; \
		echo "       macOS ships an old system Ruby by default (this is almost certainly it)."; \
		echo "       Install a current one with Homebrew:"; \
		echo "         brew install ruby"; \
		echo "       then make sure it comes before the system one on PATH (Homebrew's"; \
		echo "       installer prints the exact PATH line to add -- follow that), open a"; \
		echo "       new terminal, and confirm with 'ruby -v'. See README.md's"; \
		echo "       Prerequisites/Troubleshooting sections for details."; \
		exit 1; \
	fi
	cd scraper && bundle install

# scripts/install-ghc.sh (run via `make install`) writes .ghc-system-path
# when it had to work around a known macOS lld/configure bug (see that
# script for details) by building GHC itself instead of using Stack's own
# (broken, on the affected machine) installer. Every target below checks
# for that file at actual shell runtime -- deliberately *not* via Make's
# own $(wildcard ...) variable caching, which does not reliably notice a
# file created earlier in the same recipe or a previous `make` run.
# On an unaffected machine (most Linux systems, and most Macs) this file
# never exists, and these just run plain `stack ...` as normal.

build: ## Compile the Haskell orchestrator
	@if [ -f .ghc-system-path ]; then \
		PATH="$$(cat .ghc-system-path):$$PATH" stack build --system-ghc; \
	else \
		stack build; \
	fi

test: test-haskell test-ruby ## Run both test suites

test-haskell: ## Run the Hspec test suite
	@if [ -f .ghc-system-path ]; then \
		PATH="$$(cat .ghc-system-path):$$PATH" stack test --system-ghc; \
	else \
		stack test; \
	fi

test-ruby: ## Run the RSpec test suite
	cd scraper && bundle exec rspec

run: build ## Run web-scraper-hs-rb against $(CONFIG) (override with CONFIG=..., FORMAT=..., CONCURRENT=..., RATE=...)
	@if [ -f .ghc-system-path ]; then \
		PATH="$$(cat .ghc-system-path):$$PATH" stack exec --system-ghc web-scraper-hs-rb-exe -- \
			--config $(CONFIG) --format $(FORMAT) --max-concurrent $(CONCURRENT) --rate-limit $(RATE) --db $(DB); \
	else \
		stack exec web-scraper-hs-rb-exe -- \
			--config $(CONFIG) --format $(FORMAT) --max-concurrent $(CONCURRENT) --rate-limit $(RATE) --db $(DB); \
	fi

db-reset: ## Delete the local SQLite database
	rm -f $(DB) $(DB)-wal $(DB)-shm

clean: ## Remove build artifacts and logs
	stack clean
	rm -rf logs/*.log
