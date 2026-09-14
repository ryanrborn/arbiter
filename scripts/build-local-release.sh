#!/usr/bin/env bash
# Build an OTP release + matching `arb` escript from a local clone of this
# repo's `main` branch, for `arb server deploy --local`.
#
# Published GitHub releases lag `main` by design (a tag per release, not per
# fix); this script is the "build from HEAD of main" loop for dogfooding a
# merge within minutes instead of waiting on a tag + CI run (see
# notes/2026-09-13-switch-to-releases-scoping.md, Option B).
#
# It always builds in a *separate* clone, never the primary checkout the
# live server's own worktrees/deploys are seeded from — building in place
# would run a prod compile against the same `_build`/`deps` that dev mode
# and worker worktrees rely on, and ties the release to whatever happens to
# be checked out there at the moment the build runs.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-local-release.sh <clone-path> [output-dir]

  <clone-path>   Path to a *separate* git clone of this repo, tracking
                 origin/main. Refuses to run if this resolves to the same
                 repository as the primary checkout — including a worktree
                 of it. The primary checkout is resolved the same way the
                 server itself resolves it: $ARB_PRIMARY_CHECKOUT override,
                 else $ARB_HOME, else the path recorded by
                 `arb install-service` at ~/.config/arbiter/home, else
                 ~/dev/arbiter.
  [output-dir]   Where to write the release tarball and `arb` escript.
                 Default: <clone-path>/.local-release

On success prints two lines to stdout:
  TARBALL=<path to the arbiter-local-<sha>-<timestamp>-linux.tar.gz release>
  ESCRIPT=<path to the matching arb escript, built from the same commit>

Feed TARBALL (or the unpacked _build/prod/rel/arbiter directory) to:
  arb server deploy --local <path>
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ -z "${1:-}" ]; then
  usage >&2
  exit 1
fi

CLONE_INPUT="$1"

if [ ! -d "$CLONE_INPUT" ]; then
  echo "error: clone path does not exist: $CLONE_INPUT" >&2
  exit 1
fi

CLONE_PATH=$(cd "$CLONE_INPUT" && pwd -P)

if ! git -C "$CLONE_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: not a git repository: $CLONE_PATH" >&2
  exit 1
fi

# Resolve "the primary checkout" the same way the server itself does
# (ArbiterCli.Cmd.Start): ARB_HOME override, else the path recorded by
# `arb install-service` at ~/.config/arbiter/home, else ~/dev/arbiter.
# ARB_PRIMARY_CHECKOUT remains available as an explicit override for callers
# who know better than all of the above.
CONFIGURED_HOME_FILE="$HOME/.config/arbiter/home"
if [ -n "${ARB_PRIMARY_CHECKOUT:-}" ]; then
  PRIMARY_CHECKOUT_INPUT="$ARB_PRIMARY_CHECKOUT"
elif [ -n "${ARB_HOME:-}" ]; then
  PRIMARY_CHECKOUT_INPUT="$ARB_HOME"
elif [ -r "$CONFIGURED_HOME_FILE" ]; then
  PRIMARY_CHECKOUT_INPUT=$(cat "$CONFIGURED_HOME_FILE")
else
  PRIMARY_CHECKOUT_INPUT="$HOME/dev/arbiter"
fi

# Never build from the primary checkout, and never from a worktree of it
# either — both share the live server's source tree, and a prod compile
# there would race dev-mode hot reload and worker worktree seeding.
if [ -d "$PRIMARY_CHECKOUT_INPUT" ] &&
  git -C "$PRIMARY_CHECKOUT_INPUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PRIMARY_COMMON_DIR=$(git -C "$PRIMARY_CHECKOUT_INPUT" rev-parse --path-format=absolute --git-common-dir)
  CLONE_COMMON_DIR=$(git -C "$CLONE_PATH" rev-parse --path-format=absolute --git-common-dir)

  if [ "$PRIMARY_COMMON_DIR" = "$CLONE_COMMON_DIR" ]; then
    echo "error: refusing to build from the primary checkout or one of its worktrees ($CLONE_PATH)." >&2
    echo "       Use a separate \`git clone\` instead — never the live checkout." >&2
    exit 1
  fi
else
  echo "warning: could not resolve the primary checkout (tried ARB_PRIMARY_CHECKOUT, ARB_HOME, $CONFIGURED_HOME_FILE, $HOME/dev/arbiter) — the live-checkout guard is inactive." >&2
fi

echo "Building in $CLONE_PATH…"
cd "$CLONE_PATH"

git fetch origin main
git checkout main
git merge --ff-only origin/main

SHA=$(git rev-parse --short HEAD)
TIMESTAMP=$(date -u +%Y%m%d%H%M%S)

export MIX_ENV=prod

mix local.hex --force --if-missing
mix local.rebar --force --if-missing
mix deps.get --only prod
mix cmd --app arbiter_web mix assets.setup
mix compile
mix cmd --app arbiter_web mix assets.deploy
mix release arbiter --overwrite

(cd apps/arbiter_cli && mix escript.build)

OUTPUT_DIR="${2:-$CLONE_PATH/.local-release}"
mkdir -p "$OUTPUT_DIR"

TARBALL="$OUTPUT_DIR/arbiter-local-${SHA}-${TIMESTAMP}-linux.tar.gz"
# Package exactly like .github/workflows/release.yml: no leading top-level
# directory, so `ReleaseFiles.unpack!/2`'s generic (non-nested) branch
# handles it identically to a published release asset.
tar -czf "$TARBALL" -C "$CLONE_PATH/_build/prod/rel/arbiter" .

ESCRIPT="$OUTPUT_DIR/arb-local-${SHA}-${TIMESTAMP}"
cp "$CLONE_PATH/apps/arbiter_cli/arb" "$ESCRIPT"
chmod +x "$ESCRIPT"

echo "TARBALL=$TARBALL"
echo "ESCRIPT=$ESCRIPT"
