#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/core/target/release/notebook-style-core"

cd "$ROOT"

run() {
  echo
  echo "==> $*"
  "$@"
}

# Run a Lua file in headless Neovim (0.10 or newer, like the plugin).
# `nvim -l` exits non-zero when the script itself raises, including the error
# lua_smoke.lua raises when a test fails; `-c "luafile ..." -c 'qa!'` would
# exit 0. Errors raised in asynchronous callbacks do not change the exit
# status: lua_smoke.lua checks for those itself, and the summary check below
# catches a suite that stops early or prints anything after its summary.
run_lua() {
  nvim --headless -u NONE -l "$@"
}

run cargo fmt --manifest-path core/Cargo.toml -- --check
run cargo test --manifest-path core/Cargo.toml
run cargo build --release --manifest-path core/Cargo.toml

selfcheck="$(mktemp)"
log="$(mktemp)"
trap 'rm -f "$selfcheck" "$log"' EXIT

echo
echo "==> check that a failing Lua file fails the run"
echo "error('expected failure')" >"$selfcheck"
if run_lua "$selfcheck" >/dev/null 2>&1; then
  echo "run_lua exited 0 for a failing Lua file; Lua test failures would go unnoticed" >&2
  exit 1
fi

echo
echo "==> nvim --headless -u NONE -l tests/lua_smoke.lua"
NOTEBOOK_STYLE_TEST_ROOT="$ROOT" \
NOTEBOOK_STYLE_TEST_BACKEND="$BACKEND" \
  run_lua "$ROOT/tests/lua_smoke.lua" 2>&1 | tee "$log"

# The suite prints its summary as its very last step, and the run passes only
# if that summary is the last line of output. A missing summary means the suite
# stopped early (e.g. a stray :qa!); any output after it, such as a message or
# an error printed while Neovim exits, fails the run as well.
if ! tail -n 1 "$log" | grep -q '^notebook_style Lua smoke tests: [0-9]* passed, [0-9]* skipped, 0 failed$'; then
  echo "tests/lua_smoke.lua did not finish cleanly: its summary must be the last line of output" >&2
  exit 1
fi
