#!/usr/bin/env bash
# kube-linter (.kube-linter.yaml) on what render.sh made of each app's chart. The
# infrastructure and monitoring charts keep their authors' shape, so they're left
# out.
source "$(dirname "$0")/lib.sh"
out=${1:?directory render.sh wrote to}
files=()
for d in apps/*/; do
  app=$(basename "$d")
  ns=$(yq 'select(.kind == "HelmRelease") | .metadata.namespace' "$d/release.yaml")
  f=$out/helm-${ns}_$app.yaml
  if [ -f "$f" ]; then
    files+=("$f")
  else
    fail "$app: render.sh wrote no $f"
  fi
done
kube-linter lint --config .kube-linter.yaml "${files[@]}" || fail kube-linter
exit $failed
