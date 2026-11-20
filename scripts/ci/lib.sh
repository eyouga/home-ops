# shellcheck shell=bash disable=SC2034 # the variables are for the scripts that source this
# Sourced by the checks. Run them from anywhere; they work on the repo's tree.
set -euo pipefail
repo=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
cd "$repo"
fail() {
  echo "FAIL: $*" >&2
  failed=1
}
failed=0
# Flux writes these at bootstrap; hand edits would only be overwritten.
generated=':!clusters/def-jam/flux-system/gotk-components.yaml'
