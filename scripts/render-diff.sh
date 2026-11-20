#!/usr/bin/env bash
# render-diff.sh [<base>] : what a change does to the manifests Flux applies.
# Renders <base> (default origin/main) and the working tree with the same scripts
# (the working tree's scripts/ci), then diffs them. No output and exit 0: the change
# alters nothing Flux would apply. Run as `nix develop -c scripts/render-diff.sh`.
# An edit to a file under a configMapGenerator, a comment included, changes the
# ConfigMap's hash suffix and so the pods that mount it: expect that rename and
# nothing else.
set -euo pipefail
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
base=${1:-origin/main}
tmp=$(mktemp -d)
cleanup() {
  git -C "$repo" worktree remove --force "$tmp/base" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

git -C "$repo" worktree add --quiet --detach "$tmp/base" "$base"
# Same tooling on both sides, so only the tree differs.
rm -rf "$tmp/base/scripts/ci"
cp -R "$repo/scripts/ci" "$tmp/base/scripts/ci"

render() { # <tree> <out> <name>: quiet unless it fails
  if ! { "$1/scripts/ci/build.sh" "$2" && "$1/scripts/ci/render.sh" "$2"; } >"$tmp/$3.log" 2>&1; then
    cat "$tmp/$3.log" >&2
    echo "render-diff: $3 doesn't render" >&2
    exit 2
  fi
}
render "$tmp/base" "$tmp/before" "$base"
render "$repo" "$tmp/after" "the working tree"
diff -r -u "$tmp/before" "$tmp/after" | sed "s#$tmp/##g"
