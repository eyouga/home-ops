#!/usr/bin/env bash
# Schema validation of what build.sh rendered, and of clusters/def-jam's own
# files (Flux reads those directly, no kustomization). Strict: an unknown field
# fails, a kind without a schema fails, but CustomResourceDefinition: the only ones
# rendered are Flux's own. HelmRelease values aren't covered: their shape is the chart's.
source "$(dirname "$0")/lib.sh"
rendered=${1:?directory build.sh wrote to}

# Core Kubernetes at kube_version (lib.sh), from a pinned commit.
# renovate: datasource=git-refs depName=https://github.com/yannh/kubernetes-json-schema currentValue=master
core_rev=e62c03bd5a52fd34ff6ac28d083e2a300e0ae7c1
# Flux's schemas at the version running here.
flux_version=$(sed -nE 's/^# Flux Version: (v.+)$/\1/p' clusters/def-jam/flux-system/gotk-components.yaml)
# Every other CRD (cert-manager, CNPG, Gateway API, MetalLB, Prometheus Operator, Traefik).
# renovate: datasource=git-refs depName=https://github.com/datreeio/CRDs-catalog currentValue=main
catalog_rev=784ec895547a36e548e6810b41f27baade3a0890

schemas=$(mktemp -d)
trap 'rm -rf "$schemas"' EXIT
mkdir -p "$schemas/v$kube_version-standalone-strict"
curl -fsSL "https://github.com/fluxcd/flux2/releases/download/$flux_version/crd-schemas.tar.gz" \
  | tar xzf - -C "$schemas/v$kube_version-standalone-strict"

# sops's metadata block isn't part of a Secret; the values stay encrypted.
docs="$schemas/all.yaml"
for f in "$rendered"/*.yaml; do
  yq 'del(.sops)' "$f"
  echo '---'
done >"$docs"
git ls-files 'clusters/def-jam/*.yaml' "$generated" ':!clusters/def-jam/flux-system/*' \
  | while read -r f; do
    cat "$f"
    echo
    echo '---'
  done >>"$docs"

kubeconform -strict -summary -output pretty -skip CustomResourceDefinition \
  -kubernetes-version "$kube_version" \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$core_rev/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
  -schema-location "$schemas" \
  -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$catalog_rev/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  "$docs"
