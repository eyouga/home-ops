#!/usr/bin/env bash
# Every image this repo names is pinned by digest: `image:`, `imageName:`, and the
# charts' repository + tag pairs. Images a chart picks for itself follow the
# chart's pinned version, and gotk-components is Flux's own output.
source "$(dirname "$0")/lib.sh"
checked=0
while IFS=$'\t' read -r f ref; do
  checked=$((checked + 1))
  case "$ref" in
    *@sha256:????????????????????????????????????????????????????????????????) ;;
    *) fail "$f: $ref isn't pinned by digest" ;;
  esac
done < <(git ls-files '*.yaml' ':!*.sops.yaml' ':!.sops.yaml' ':!monitoring/dashboards/*' ':!.github/*' "$generated" | while read -r f; do
  yq -o=tsv '
    [ .. | select(tag == "!!map") |
      ( select(has("repository") and has("tag")) | .repository + ":" + .tag ),
      ( select(has("image") and (.image | tag == "!!str")) | .image ),
      ( select(has("imageName")) | .imageName )
    ] | unique | .[] | [filename, .]' "$f"
done | grep -v '^---$' || true)
[ "$checked" -gt 0 ] || fail "no image reference found: this check is broken"
echo "$checked image references checked"
exit $failed
