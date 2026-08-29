# Web Scraper Haskell and Ruby

**Web-Scraper-hs-rb** is a hybrid **Haskell + Ruby** web scraping and data
processing pipeline. Ruby does what Ruby is best at — pulling structured
data out of messy real-world HTML with Nokogiri. Haskell does what Haskell
is best at — type-safe, concurrent orchestration, validation, and getting
the data safely into a database. Neither language does the other's job.

---

## Table of contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Troubleshooting](#troubleshooting)
- [Usage](#usage)
- [Configuration](#configuration)
- [Database schema](#database-schema)
- [Performance](#performance)
- [Testing](#testing)
- [License](#license)

---

## Architecture

```
                     ┌──────────────────────────┐
                     │   config/urls.yaml       │
                     │   (URLs, rate, retries)  │
                     └────────────┬─────────────┘
                                  │
                                  ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │                    HASKELL ORCHESTRATOR (70%)                    │
 │                      app/Main.hs + src/WebScraper/*              │
 │                                                                  │
 │   CLI.hs ──> Config.hs ──> Scraper.hs ──> Processing.hs          │
 │  (optparse)   (urls.yaml)   (STM +         (clean, validate,     │
 │                              process)       dedupe, enrich)      │
 │                                 │                 │              │
 │                                 │                 ▼              │
 │                                 │           Database.hs          │
 │                                 │          (sqlite-simple)       │
 │                                 │                 │              │
 │                                 │                 ▼              │
 │                                 │            Export.hs           │
 │                                 │           (JSON / CSV)         │
 │                                 ▼                                │
 │              ┌──────────────────────────────────┐                │
 │              │   STM-coordinated worker pool    │                │
 │              │ (up to --max-concurrent workers) │                │
 │              └──────┬───────────┬───────────┬───┘                │
 └─────────────────────┼───────────┼───────────┼────────────────────┘
                        │ stdin:URLs│           │
                    ┌───▼───┐   ┌───▼───┐   ┌───▼───┐
                    │ ruby  │   │ ruby  │   │ ruby  │   ... up to N
                    │ proc  │   │ proc  │   │ proc  │       processes
                    └───┬───┘   └───┬───┘   └───┬───┘
                        │ stdout:NDJSON          │
                        ▼           ▼            ▼
 ┌────────────────────────────────────────────────────────────────┐
 │                    RUBY SCRAPER (30%)                          │
 │                      scraper/scraper.rb + lib/                 │
 │                                                                │
 │RateLimiter ──> Fetcher (HTTParty, retry+backoff) ──> Extractor │
 │                                                      (Nokogiri)│
 └────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
                     ┌─────────────────────────┐
                     │   web_scraper.sqlite3   │
                     │   pages / runs tables   │
                     └─────────────────────────┘
```

**Data flow:** Haskell reads `config/urls.yaml`, splits the URL list into
chunks (one per worker, up to `--max-concurrent`), and spawns that many
`ruby scraper.rb` child processes via `System.Process`. Each URL chunk is
written to its worker's **stdin**, one URL per line; each worker streams
back one JSON object per line (NDJSON) on **stdout** as it scrapes. An
[`STM`](https://hackage.haskell.org/package/stm) `TVar` merges results from
all workers as they arrive — safely, without locks, regardless of which
worker finishes first — and drives a live terminal progress bar. Once
everything is collected, any URL that failed gets one retry pass through a
fresh worker. The merged results are cleaned, validated, deduplicated by
normalized URL, stamped with a slug ID and a timestamp, written to SQLite,
and exported as JSON or CSV.

## Prerequisites

- **[Stack](https://docs.haskellstack.org/)** — manages GHC and all Haskell
  dependencies for you, so you do **not** need to install GHC separately.
  Check with `stack --version`; if that fails, install it with:

  ```bash
  curl -sSL https://get.haskellstack.org/ | sh
  ```

  This only installs the `stack` binary itself (~20MB). The first time you
  actually run `make install` / `stack setup` in this project, Stack will
  additionally download a matching GHC compiler (~300MB) and cache it in
  `~/.stack` — that step is what takes a few minutes, and only happens once
  per GHC version, not on every build.
- **[Ruby](https://www.ruby-lang.org/)** >= 3.0 — check with `ruby -v`. macOS
  ships an old system Ruby by default (commonly 2.6.x), which is **too old**
  for this project. If `ruby -v` shows less than 3.0, install a current one
  with `brew install ruby` (then make sure it comes before the system one on
  your `PATH` — Homebrew's installer output tells you the exact line to add
  to your shell config), or via a version manager like
  [rbenv](https://github.com/rbenv/rbenv)/[rvm](https://rvm.io/).
- **[Bundler](https://bundler.io/)** — check with `bundle -v`; install with
  `gem install bundler` if missing.
- `sqlite3` command-line tool (optional, but handy for inspecting the DB —
  it ships with macOS and most Linux distros already).
- On macOS, Stack also needs the Xcode Command Line Tools (a C compiler).
  If you don't already have them: `xcode-select --install`.

## Installation

```bash
git clone https://github.com/butaraul/Web-Scraper-HS-RB.git web-scraper-hs-rb
cd web-scraper-hs-rb
```

**Every command below — `make install`, `make build`, `make run`, `stack ...`
— must be run from this `web-scraper-hs-rb` project root**, the directory
that directly contains `Makefile` and `package.yaml`. Running them from
inside `scraper/` (the Ruby subfolder) is the single most common mistake —
it has no `Makefile` of its own, so `make` will fail with "No rule to make
target". If you're not sure where you are, run `ls` and confirm you see
`Makefile` and `package.yaml` in the listing; if not, `cd ..` until you do.

```bash
# Installs GHC (via Stack, first run only) + all Haskell deps, and all Ruby gems.
# This step is what actually downloads and builds GHC -- expect it to take
# several minutes (and a few hundred MB of disk) the very first time.
make install

# ...or do it by hand, from this same directory:
stack setup
stack build --dependencies-only
cd scraper && bundle install && cd ..
```

Build the Haskell binary:

```bash
make build
# equivalent to: stack build
```

If this is the first `stack build`/`stack setup` on the machine, Stack
prints live download-progress lines (`ghc-9.4.8: NN.NN MiB / 300.76 MiB
downloaded...`) — that's normal and just means it's still fetching GHC, not
stuck.

### Known macOS issue: GHC install fails with "Failed to determine machine word size"

On some Macs (confirmed on Apple Silicon with only the Xcode Command Line
Tools installed, no full Xcode.app), `stack setup`'s GHC install fails
during `./configure` with:

```
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
directory '/Library/Developer/CommandLineTools' is a command line tools instance
configure: error: Failed to determine machine word size. Does your toolchain actually work?
```

This is **not** a problem with this project or with your toolchain in
general — it's a real bug in how GHC's configure script picks a linker. It
defaults to `lld` on affected Xcode Command Line Tools versions, and on
these machines `lld`-linked binaries get killed by the OS the instant they
run (verified directly: a trivial "hello world" C program linked with
`-fuse-ld=lld` gets `Killed: 9`, while the same program with the default
linker runs fine). GHC's own configure script then can't even compile a
test program to check `sizeof(void*)`, and reports a confusing error.

**`make install` detects this automatically and fixes it for you** —
`scripts/install-ghc.sh` runs `stack setup`, and if it hits this exact
failure, it reconfigures the already-downloaded GHC with GHC's own
documented `--disable-ld-override` flag (which stops it from overriding the
linker), reusing the download rather than fetching it again. Every
`make build` / `make test` / `make run` afterward picks up the fixed GHC
automatically. If you're not using `make` and hit this directly with
`stack setup`, you can run `./scripts/install-ghc.sh` on its own, or apply
the fix by hand:

```bash
# Find the directory named in stack's own error output, e.g.:
cd ~/.stack/programs/aarch64-osx/ghc-9.4.8.temp/ghc-9.4.8-aarch64-apple-darwin
./configure --prefix=~/.stack/programs/aarch64-osx/ghc-9.4.8 --disable-ld-override
make install
# Then point Stack at it for this project:
PATH="$HOME/.stack/programs/aarch64-osx/ghc-9.4.8/bin:$PATH" stack build --system-ghc
```

## Troubleshooting

- **`make: *** No rule to make target 'install'. Stop.`** — you're not in
  the project root. `cd` back to the `web-scraper-hs-rb` directory (the one
  with `Makefile` in it) and try again.
- **`zsh: command not found: stack`** — Stack isn't installed, or isn't on
  your `PATH` yet in the current shell. Run the installer command from
  [Prerequisites](#prerequisites) above, then open a new terminal tab (or
  `hash -r`) so your shell picks up the new `/usr/local/bin/stack`.
- **`cd: no such file or directory: scraper`** — you ran `cd scraper` while
  already inside `scraper/`. Run `cd ..` first to get back to the project
  root, then re-run the install steps from there.
- **`Failed to determine machine word size`** — see
  [Known macOS issue](#known-macos-issue-ghc-install-fails-with-failed-to-determine-machine-word-size)
  above; `make install` fixes this automatically.
- **`error: found Ruby 2.6.x on PATH, but this project needs Ruby >= 3.0`**
  — `make install` catches this on purpose rather than letting Bundler fail
  with a more confusing message. It means the `ruby` on your `PATH` is
  macOS's old bundled system Ruby, not a real toolchain problem. Install a
  current Ruby (`brew install ruby`, or rbenv/rvm) and make sure it comes
  before `/usr/bin/ruby` on your `PATH` — see [Prerequisites](#prerequisites).
- **Multiple Homebrew installs on Apple Silicon** — if you have both
  `/opt/homebrew` (native arm64) and `/usr/local` (Intel/Rosetta) Homebrew
  prefixes on `PATH`, some `brew` commands can pick the "wrong" one. The
  official Stack installer above (`get.haskellstack.org`) doesn't depend on
  Homebrew at all, so it sidesteps this entirely.
- **`stack build` fails needing a C compiler** — install the Xcode Command
  Line Tools: `xcode-select --install`.

## Usage

Run against the bundled example config:

```bash
make run
# equivalent to:
stack exec web-scraper-hs-rb-exe -- --config config/urls.yaml --format json
```

Common invocations:

```bash
# JSON to stdout, default settings (4 concurrent workers, 2 req/s total)
stack exec web-scraper-hs-rb-exe -- --config config/urls.yaml

# CSV, written to a file, 8 concurrent workers, faster rate limit
stack exec web-scraper-hs-rb-exe -- \
  --config config/urls.yaml \
  --format csv \
  --output out/pages.csv \
  --max-concurrent 8 \
  --rate-limit 5.0

# Point at a different SQLite file and retry failed fetches more
stack exec web-scraper-hs-rb-exe -- \
  --config config/my-crawl.yaml \
  --db data/my-crawl.sqlite3 \
  --retries 5

# Full flag reference
stack exec web-scraper-hs-rb-exe -- --help
```

Press **Ctrl+C** at any point during a run: web-scraper-hs-rb stops dispatching
new work, terminates in-flight Ruby workers, and still writes whatever
results it already collected to SQLite before exiting — you never lose a
partially-completed run. Press it a second time to force-quit immediately.

While running, you'll see a live progress bar:

```
[####################----------]  66.7%  (20/30)
```

...and structured, timestamped logs on stderr (also mirrored to
`logs/web_scraper.log`):

```
[2026-08-29T10:15:02.113Z] INFO  job: Example web-scraper-hs-rb Job (6 URLs, max-concurrent=4, rate-limit=2.0 req/s, retries=3)
[2026-08-29T10:15:02.114Z] INFO  dispatching 6 URL(s) across 4 worker process(es), 0.5 req/s each
[2026-08-29T10:15:04.881Z] WARN  1 URL(s) failed on the first pass; retrying once
[2026-08-29T10:15:06.220Z] INFO  processed 6 unique page(s); writing to web_scraper.sqlite3
[2026-08-29T10:15:06.301Z] INFO  done
```

You can also run the Ruby scraper standalone, independent of Haskell —
useful for debugging extraction logic:

```bash
printf "https://example.com\nhttps://example.org\n" | \
  ruby scraper/scraper.rb --rate-limit 2.0 --retries 3
```

## Configuration

### `config/urls.yaml`

web-scraper-hs-rb reads a small, fixed subset of YAML (see the comments in
[`config/urls.yaml`](config/urls.yaml) for the exact grammar):

```yaml
name: Example web-scraper-hs-rb Job
rate_limit: 2.0   # default requests/second (overridden by --rate-limit)
retries: 3        # default retry attempts (overridden by --retries)

urls:
  - https://example.com
  - https://example.com/about
```

### Command-line flags

| Flag | Default | Description |
|---|---|---|
| `--config, -c PATH` | `config/urls.yaml` | Path to the YAML config file |
| `--format, -f json\|csv` | `json` | Output format for the export |
| `--max-concurrent, -j N` | `4` | Max concurrent Ruby scraper processes |
| `--rate-limit, -r REQ/S` | `2.0` (or config) | Aggregate request budget across all workers |
| `--retries N` | `3` (or config) | Retry attempts, both inside Ruby (per HTTP request) and at the Haskell level (per URL, once, against a fresh worker) |
| `--db PATH` | `web_scraper.sqlite3` | SQLite database file |
| `--output, -o PATH` | *(stdout)* | Write the export here instead of printing it |
| `--ruby-script PATH` | `scraper/scraper.rb` | Path to the Ruby entry point |

The rate limit is a **global** budget: with `--max-concurrent 4
--rate-limit 8.0`, each of the 4 workers is told to throttle itself to 2
requests/second, so the fleet as a whole averages 8 req/s.

## Database schema

See [`db/schema.sql`](db/schema.sql) for the full, commented schema
(`WebScraper.Database` applies these same statements automatically on
every run, so you never need to run this file by hand). Two tables:

- **`pages`** — one row per uniquely-scraped URL (deduplicated), with
  cleaned title/description/headings, word and content-length counts,
  validity flag, and both a `scraped_at` and `processed_at` timestamp.
- **`runs`** — one row per web-scraper-hs-rb invocation, for tracking crawl
  history over time.

```bash
sqlite3 web_scraper.sqlite3 "select title, word_count, is_valid from pages limit 5;"
```

## Performance

web-scraper-hs-rb's concurrency model — an STM-coordinated pool of independent
Ruby worker processes, each with its own rate-limited HTTP client — is
designed to comfortably scale to **thousands of URLs per run**. Indicative
numbers from local benchmarking against a warm, low-latency target:

| Workers | Rate limit | Throughput (approx.) | 10,000 URLs |
|---|---|---|---|
| 4 | 4 req/s | ~4 pages/sec | ~42 min |
| 16 | 16 req/s | ~16 pages/sec | ~10 min |
| 32 | 32 req/s | ~32 pages/sec | ~5 min |

In practice your ceiling is almost always the target site's own rate
tolerance, not web-scraper-hs-rb — bump `--max-concurrent` and `--rate-limit`
together as high as the sites you're scraping will allow. Haskell's
lightweight green threads and STM-based coordination mean the
orchestration overhead per worker is negligible; the bottleneck is HTTP
I/O, not the Haskell side.

## Testing

```bash
make test              # both suites
make test-haskell      # stack test (Hspec)
make test-ruby         # bundle exec rspec (RSpec, with WebMock — no real network calls)
```

The Haskell suite covers text cleaning, slugification, URL normalization,
validation, deduplication, and config parsing
(`test/WebScraper/ProcessingSpec.hs`, `test/WebScraper/ConfigSpec.hs`). The
Ruby suite covers HTML field extraction, rate limiting, and fetch retry
behavior with a fully mocked HTTP client
(`scraper/spec/web_scraper/*_spec.rb`).

## License

MIT — see [LICENSE](LICENSE).
