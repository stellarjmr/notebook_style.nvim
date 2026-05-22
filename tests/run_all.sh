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

run cargo fmt --manifest-path core/Cargo.toml -- --check
run cargo test --manifest-path core/Cargo.toml
run cargo build --release --manifest-path core/Cargo.toml

echo
echo "==> nvim --headless tests/lua_smoke.lua"
NOTEBOOK_STYLE_TEST_ROOT="$ROOT" \
NOTEBOOK_STYLE_TEST_BACKEND="$BACKEND" \
  nvim --headless -u NONE -c "luafile $ROOT/tests/lua_smoke.lua" -c 'qa!'
