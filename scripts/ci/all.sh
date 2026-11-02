#!/usr/bin/env bash
# Everything a PR must pass, in one command: `nix develop -c scripts/ci/all.sh`.
# No secrets, no cluster: it reads the tree and public URLs. Every check runs, so one
# log shows all that's wrong.
source "$(dirname "$0")/lib.sh"
ci=$repo/scripts/ci
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for check in "build.sh $out" "render.sh $out" "validate.sh $out" secrets.sh images.sh plugin-pins.sh "probes.sh $out"; do
  echo "::group::$check"
  # shellcheck disable=SC2086
  bash "$ci/"$check || fail "$check"
  echo "::endgroup::"
done
exit $failed
