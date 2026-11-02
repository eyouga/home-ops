#!/usr/bin/env bash
# Every image this repo names is pinned by digest: `image:`, `imageName:`, and the
# charts' repository + tag pairs. Images a chart picks for itself follow the
# chart's pinned version, and gotk-components is Flux's own output.
source "$(dirname "$0")/lib.sh"
checked=0
while read -r f; do
  if ! refs=$(yq '
    [ .. | select(tag == "!!map") |
      ( select(has("repository") and has("tag")) | .repository + ":" + .tag ),
      ( select(has("image") and (.image | tag == "!!str")) | .image ),
      ( select(has("image") and (.image | tag == "!!map") and (.image | has("repository")) and (.image | has("tag") | not)) | .image.repository ),
      ( select(has("imageName")) | .imageName )
    ] | unique | .[]' "$f"); then
    fail "$f doesn't parse"
    continue
  fi
  while read -r ref; do
    case "$ref" in
      "" | ---) continue ;;
      *@sha256:????????????????????????????????????????????????????????????????) ;;
      *) fail "$f: $ref isn't pinned by digest" ;;
    esac
    checked=$((checked + 1))
  done <<<"$refs"
done < <(git ls-files '*.yaml' ':!*.sops.yaml' ':!.sops.yaml' ':!monitoring/dashboards/*' ':!.github/*' "$generated")
[ "$checked" -gt 0 ] || fail "no image reference found: this check is broken"
echo "$checked image references checked"
exit $failed
