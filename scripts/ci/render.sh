#!/usr/bin/env bash
# Each HelmRelease rendered by its chart with its real values, into $1 next to what
# build.sh wrote, so validate.sh checks the result too. A chart upgrade that no longer
# fits its values goes red here: a chart's values.schema.json, a required value, a
# template that fails, an object the schemas refuse. No cluster and no secrets: only
# ConfigMaps can feed values here, and a Secret in valuesFrom fails, on purpose.
# It doesn't prove the app starts, only that Flux could install it.
source "$(dirname "$0")/lib.sh"
out=${1:?directory build.sh wrote to}
# What the cluster runs and offers: `helm template` can't ask it.
kube_version=1.36.5
api_versions=(monitoring.coreos.com/v1 gateway.networking.k8s.io/v1 cert-manager.io/v1 postgresql.cnpg.io/v1 metallb.io/v1beta1 traefik.io/v1alpha1)

charts=$(mktemp -d) tmp=$(mktemp -d)
trap 'rm -rf "$charts" "$tmp"' EXIT
# Layers only: the per-app builds repeat what's in them. One stream to look things up in.
all=$tmp/all.yaml
for layer in apps monitoring infrastructure_controllers; do cat "$out/$layer.yaml"; echo '---'; done >"$all"

fetch() { # <url> <chart> <version>: the chart's .tgz, once per version
  local url=$1 chart=$2 version=$3 dir
  dir=$charts/$(echo "$url/$chart" | tr -c 'a-zA-Z0-9\n' _)-$version
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    case "$url" in
      oci://*) helm pull "$url" --version "$version" --destination "$dir" >&2 ;;
      *) helm pull "$chart" --repo "$url" --version "$version" --destination "$dir" >&2 ;;
    esac
  fi
  echo "$dir"/*.tgz
}

rendered=0
while IFS=/ read -r ns name; do
  id=$ns/$name
  hr() { NS=$ns NAME=$name yq "select(.kind == \"HelmRelease\" and .metadata.namespace == env(NS) and .metadata.name == env(NAME)) | $1" "$all" | grep -v '^---$' || true; }
  source_kind=$(hr '.spec.chartRef.kind // ""')
  if [ "$source_kind" = OCIRepository ]; then
    ref=$(hr '.spec.chartRef.name')
    url=$(NS=$ns REF=$ref yq 'select(.kind == "OCIRepository" and .metadata.namespace == env(NS) and .metadata.name == env(REF)) | .spec.url' "$all" | grep -v '^---$')
    version=$(NS=$ns REF=$ref yq 'select(.kind == "OCIRepository" and .metadata.namespace == env(NS) and .metadata.name == env(REF)) | .spec.ref.tag' "$all" | grep -v '^---$')
    chart=
  else
    ref=$(hr '.spec.chart.spec.sourceRef.name')
    chart=$(hr '.spec.chart.spec.chart')
    version=$(hr '.spec.chart.spec.version')
    url=$(NS=$ns REF=$ref yq 'select(.kind == "HelmRepository" and .metadata.namespace == env(NS) and .metadata.name == env(REF)) | .spec.url' "$all" | grep -v '^---$')
  fi
  if [ -z "$url" ] || [ -z "$version" ]; then fail "$id: can't find its chart"; continue; fi

  args=()
  i=0
  while IFS=$'\t' read -r kind cm key; do
    [ -n "$kind" ] || continue
    if [ "$kind" != ConfigMap ]; then fail "$id: valuesFrom a $kind can't be rendered without secrets"; continue; fi
    i=$((i + 1))
    NS=$ns CM=$cm KEY=${key:-values.yaml} yq 'select(.kind == "ConfigMap" and .metadata.namespace == env(NS) and .metadata.name == env(CM)) | .data[env(KEY)]' "$all" | grep -v '^---$' >"$tmp/from-$i.yaml"
    args+=(-f "$tmp/from-$i.yaml")
  done < <(hr '.spec.valuesFrom[]? | [.kind, .name, .valuesKey // ""] | @tsv')
  hr '.spec.values // {}' >"$tmp/values.yaml"
  args+=(-f "$tmp/values.yaml")
  for a in "${api_versions[@]}"; do args+=(--api-versions "$a"); done

  if ! tgz=$(fetch "$url" "$chart" "$version"); then fail "$id: can't fetch $url $chart $version"; continue; fi
  f=$out/helm-${ns}_$name.yaml
  if helm template "$name" "$tgz" --namespace "$ns" --kube-version "$kube_version" "${args[@]}" >"$f" 2>"$tmp/err"; then
    rendered=$((rendered + 1))
    echo "ok   $id"
  else
    sed 's/^/     /' "$tmp/err" >&2
    rm -f "$f"
    fail "$id doesn't render with chart $chart$url $version"
  fi
done < <(yq 'select(.kind == "HelmRelease") | .metadata.namespace + "/" + .metadata.name' "$all" | grep -v '^---$' | sort -u)
[ "$rendered" -gt 0 ] || fail "nothing rendered: this check is broken"
echo "$rendered HelmReleases rendered"
exit $failed
