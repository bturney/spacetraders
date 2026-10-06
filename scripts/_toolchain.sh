#!/usr/bin/env bash
# Shared toolchain resolution for the spacetraders scripts.
#
# Locates a pinned Erlang/OTP + Elixir toolchain. Sources are:
#   1. `SPACETRADERS_TOOLCHAIN_DIR` if set (override install dir)
#   2. a toolchain already installed by scripts/bootstrap under
#      `$HOME/.local/opt/spacetraders-toolchain`
#   3. whatever `erl`/`mix` is already on PATH
#
# After sourcing, scripts should `exec` or `export PATH` to pick up
# `$MIX`/`$ERL` when the toolchain was installed locally.
set -euo pipefail

TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_VERSIONS="$TC_DIR/../.tool-versions"

# Versions are owned by .tool-versions; override per-run via env if needed.
OTP_VERSION="${SPACETRADERS_OTP_VERSION:-$(awk '/^erlang /{print $2}' "$TOOL_VERSIONS")}"
ELIXIR_VERSION="${SPACETRADERS_ELIXIR_VERSION:-$(awk '/^elixir /{print $2}' "$TOOL_VERSIONS" | sed 's/-otp-.*//')}"

TOOLCHAIN_DIR="${SPACETRADERS_TOOLCHAIN_DIR:-$HOME/.local/opt/spacetraders-toolchain}"
OTP_DIR="$TOOLCHAIN_DIR/otp-$OTP_VERSION"
ELIXIR_DIR="$TOOLCHAIN_DIR/elixir-$ELIXIR_VERSION"

OTP_URL="https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-$OTP_VERSION.tar.gz"
ELIXIR_URL="https://github.com/elixir-lang/elixir/releases/download/v$ELIXIR_VERSION/elixir-otp-27.zip"

export OTP_VERSION ELIXIR_VERSION TOOLCHAIN_DIR OTP_DIR ELIXIR_DIR OTP_URL ELIXIR_URL

# Once installed, prepend the pinned toolchain to PATH so `source scripts/_toolchain.sh`
# is the whole dev-shell setup. On a cold machine the binaries below do not exist yet,
# PATH is left alone, and scripts/bootstrap performs the install.
if [ -x "$ELIXIR_DIR/bin/mix" ] && [ -x "$OTP_DIR/bin/erl" ]; then
  export PATH="$ELIXIR_DIR/bin:$OTP_DIR/bin:$PATH"
fi

# Ordinary checkouts use the installed dependency directory. `worktree-setup`
# writes a local override so concurrent ticket work never mutates it.
export MIX_DEPS_PATH="${MIX_DEPS_PATH:-$TOOLCHAIN_DIR/deps}"

WORKTREE_ENV_FILE="$TC_DIR/../.worktree-env"
if [ -f "$WORKTREE_ENV_FILE" ]; then
  # This file is generated only by scripts/worktree-setup and keeps ordinary
  # project commands on the task's private build, deps, and HTTP port.
  source "$WORKTREE_ENV_FILE"
fi
