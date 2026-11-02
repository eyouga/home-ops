#!/usr/bin/env bash
# kustomize build of every kustomization in the repo, each layer and each app
# on its own, into $1 for validate.sh. A *.sops.yaml goes through as it is: only
# its values are encrypted, so this needs no key.
source "$(dirname "$0")/lib.sh"
out=${1:?output directory}
mkdir -p "$out"
while read -r k; do
  dir=$(dirname "$k")
  if kustomize build --load-restrictor LoadRestrictionsNone "$dir" >"$out/${dir//\//_}.yaml"; then
    echo "ok   $dir"
  else
    fail "kustomize build $dir"
  fi
done < <(git ls-files '*kustomization.yaml')
exit $failed
