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

# Run a Lua file in headless Neovim. `nvim -l` (Neovim 0.9+) exits non-zero on
# any Lua error, including the error lua_smoke.lua raises when a test fails.
# `-c "luafile ..." -c 'qa!'` must not be used: it exits 0 after a Lua error.
run_lua() {
  nvim --headless -u NONE -l "$@"
}

run cargo fmt --manifest-path core/Cargo.toml -- --check
run cargo test --manifest-path core/Cargo.toml
run cargo build --release --manifest-path core/Cargo.toml

echo
echo "==> check that a failing Lua file fails the run"
selfcheck="$(mktemp)"
trap 'rm -f "$selfcheck"' EXIT
echo "error('expected failure')" >"$selfcheck"
if run_lua "$selfcheck" >/dev/null 2>&1; then
  echo "run_lua exited 0 for a failing Lua file; Lua test failures would go unnoticed" >&2
  exit 1
fi

echo
echo "==> nvim --headless -u NONE -l tests/lua_smoke.lua"
NOTEBOOK_STYLE_TEST_ROOT="$ROOT" \
NOTEBOOK_STYLE_TEST_BACKEND="$BACKEND" \
  run_lua "$ROOT/tests/lua_smoke.lua"
