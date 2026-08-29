#!/usr/bin/env bash
#
# Installs GHC via `stack setup`, and automatically works around a known
# macOS issue: on some Apple Silicon Macs with only the Xcode Command Line
# Tools installed (no full Xcode.app), GHC's own ./configure step detects
# and prefers the `lld` linker, and binaries linked with `lld` get killed
# by the OS the instant they run (SIGKILL / exit 137) -- even a trivial
# "hello world" C program. GHC's configure then reports the misleading
# "Failed to determine machine word size. Does your toolchain actually
# work?", when the real problem is specifically lld-linked output, not the
# toolchain in general (a normal, non-lld build works fine).
#
# GHC ships a documented fix for exactly this: the --disable-ld-override
# configure flag, which stops it from overriding the linker and falls back
# to the system default. `stack setup` has no CLI flag to pass this
# through, so this script detects the specific failure, re-runs GHC's own
# configure by hand with that flag against the already-downloaded bindist
# (no re-download), and records the result so the Makefile can point Stack
# at it automatically from then on.
#
# Safe to re-run: if a previous run already fixed things, this exits
# immediately; on an unrelated failure, it prints the real error and exits
# non-zero rather than guessing.

set -euo pipefail
cd "$(dirname "$0")/.."

GHC_PATH_FILE=".ghc-system-path"

# Already fixed by a previous run and still working? Nothing to do.
if [ -f "$GHC_PATH_FILE" ]; then
  existing="$(cat "$GHC_PATH_FILE")"
  if [ -x "$existing/ghc" ] && "$existing/ghc" --version >/dev/null 2>&1; then
    echo "==> GHC already installed and working at $existing (from a previous run)."
    exit 0
  fi
  rm -f "$GHC_PATH_FILE"
fi

echo "==> Running 'stack setup'..."
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

if stack setup 2>&1 | tee "$LOG"; then
  echo "==> GHC installed successfully."
  exit 0
fi

if ! grep -q "Failed to determine machine word size" "$LOG"; then
  echo ""
  echo "==> 'stack setup' failed for a reason this script doesn't recognize."
  echo "    See the output above, and README.md's Troubleshooting section."
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo ""
  echo "==> Hit the 'Failed to determine machine word size' error, but this"
  echo "    isn't macOS, so the known auto-fix doesn't apply here."
  echo "    See README.md's Troubleshooting section."
  exit 1
fi

echo ""
echo "==> Detected the known macOS lld/configure issue."
echo "    Working around it by reconfiguring GHC with --disable-ld-override"
echo "    (reuses the already-downloaded GHC -- no re-download needed)."
echo ""

# Stack's own error output names the exact failed configure command and the
# directory it ran in -- pull both from there instead of guessing paths or
# GHC version numbers.
CONFIGURE_DIR="$(grep "Run from:" "$LOG" | tail -1 | sed 's/^ *Run from: *//')"
PREFIX="$(grep "Raw command:" "$LOG" | tail -1 | sed -n 's/.*--prefix=\([^ ]*\).*/\1/p')"

if [ -z "$CONFIGURE_DIR" ] || [ -z "$PREFIX" ] || [ ! -d "$CONFIGURE_DIR" ]; then
  echo "==> Could not locate the failed configure directory/prefix in stack's"
  echo "    output to auto-repair. Please follow the manual steps in"
  echo "    README.md's Troubleshooting section instead."
  exit 1
fi

echo "==> Reconfiguring GHC in: $CONFIGURE_DIR"
(
  cd "$CONFIGURE_DIR"
  ./configure --prefix="$PREFIX" --disable-ld-override
  make install
)

GHC_BIN="${PREFIX%/}/bin"
if [ ! -x "$GHC_BIN/ghc" ] || ! "$GHC_BIN/ghc" --version >/dev/null 2>&1; then
  echo "==> Rebuild finished, but $GHC_BIN/ghc isn't there or doesn't run."
  echo "    See README.md's Troubleshooting section for the manual steps"
  echo "    this script just tried to automate."
  exit 1
fi

echo "$GHC_BIN" > "$GHC_PATH_FILE"

echo ""
echo "==> Fixed. GHC is installed and working at: $GHC_BIN"
echo "    'make build' / 'make test' / 'make run' will automatically use it"
echo "    from now on (via $GHC_PATH_FILE)."
