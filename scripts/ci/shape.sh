#!/usr/bin/env bash
# Every app has the same shape (docs/architecture.md), as far as kube-linter
# (kube-lint.sh) can't see it: its files in one order, a restricted namespace
# that denies by default, a Helm timeout longer than its startup probe allows and
# shorter than the apps layer waits for it, and its generated ConfigMap named
# <app>-files. An app that differs says why on
# a `# shape: <rule>: <why>` line in its directory; an exception that isn't
# needed any more fails too.
source "$(dirname "$0")/lib.sh"
out=${1:?directory build.sh and render.sh wrote to}
layers=$(mktemp)
trap 'rm -f "$layers"' EXIT
for layer in apps infrastructure_configs infrastructure_controllers; do
  cat "$out/$layer.yaml"
  echo '---'
done >"$layers"

order=(namespace.yaml networkpolicy.yaml '*.sops.yaml' database.yaml storage.yaml release.yaml route.yaml)
rank() { # <file>: its place in $order, or nothing
  local i
  for i in "${!order[@]}"; do
    # shellcheck disable=SC2053 # a glob on purpose: *.sops.yaml
    if [[ $1 == ${order[$i]} ]]; then
      echo "$i"
      return
    fi
  done
}
seconds() { # <Go duration> as Helm reads it: 15m, 1h, 90s
  local d=$1 total=0 n unit
  while [[ $d =~ ^([0-9]+)([hms])(.*)$ ]]; do
    n=${BASH_REMATCH[1]} unit=${BASH_REMATCH[2]} d=${BASH_REMATCH[3]}
    case $unit in h) total=$((total + n * 3600)) ;; m) total=$((total + n * 60)) ;; s) total=$((total + n)) ;; esac
  done
  echo "$total"
}

# The apps layer (wait: true) gives up on an app's health after this.
layer=$(seconds "$(yq '.spec.timeout // "5m"' clusters/def-jam/apps.yaml)")

for dir in apps/*/; do
  app=$(basename "$dir")
  excused() { grep -rqs "# shape: $1:" "$dir"; }
  check() { # <rule> <passes: true|false> <message>
    if [ "$2" = true ] && excused "$1"; then
      fail "$app: says why it breaks '$1', but it doesn't any more: drop the '# shape: $1:' line"
    elif [ "$2" = false ] && ! excused "$1"; then
      fail "$app: $3 (or say why on a '# shape: $1: <why>' line)"
    fi
  }

  last=-1 ok=true
  while read -r f; do
    r=$(rank "$f")
    if [ -z "$r" ] || [ "$r" -lt "$last" ]; then ok=false; fi
    last=${r:-$last}
  done < <(yq '.resources[]' "$dir/kustomization.yaml")
  check order "$ok" "kustomization.yaml lists its resources out of order: ${order[*]}"

  ns=$(yq 'select(.kind == "HelmRelease") | .metadata.namespace' "$dir/release.yaml")
  labels=$(NS=$ns yq 'select(.kind == "Namespace" and .metadata.name == env(NS)) | .metadata.labels | to_entries | .[] | .key + "=" + .value' "$layers")
  ok=true
  for l in enforce warn; do grep -qx "pod-security.kubernetes.io/$l=restricted" <<<"$labels" || ok=false; done
  check restricted "$ok" "namespace $ns isn't Pod Security restricted (enforce and warn)"

  deny=$(NS=$ns yq 'select(.kind == "NetworkPolicy" and .metadata.namespace == env(NS) and (.spec.podSelector | length) == 0 and (.spec.policyTypes | contains(["Ingress", "Egress"]))) | .metadata.name' "$layers" | grep -cv '^---$' || true)
  check default-deny "$([ "$deny" -gt 0 ] && echo true || echo false)" "namespace $ns has no default-deny NetworkPolicy"

  timeout=$(seconds "$(yq 'select(.kind == "HelmRelease") | .spec.timeout // "5m"' "$dir/release.yaml")")
  allowance=$(yq ea '[select(.kind == "Deployment" or .kind == "StatefulSet") | .spec.template.spec.containers[].startupProbe | select(.)
    | (.initialDelaySeconds // 0) + (.periodSeconds // 10) * (.failureThreshold // 3)] | .[]' "$out/helm-${ns}_$app.yaml" | sort -n | tail -1)
  allowance=${allowance:-0}
  check timeout "$([ "$timeout" -gt "$allowance" ] && echo true || echo false)" "Helm's timeout (${timeout}s) isn't longer than the startup probe allows (${allowance}s)"
  check layer-timeout "$([ "$layer" -gt "$timeout" ] && echo true || echo false)" "Helm's timeout (${timeout}s) isn't shorter than the apps layer's (${layer}s, clusters/def-jam/apps.yaml)"

  names=$(yq '.configMapGenerator[].name' "$dir/kustomization.yaml")
  check files-name "$([ -z "$names" ] || [ "$names" = "$app-files" ] && echo true || echo false)" "its generated ConfigMap is $names, not $app-files"
done
exit $failed
