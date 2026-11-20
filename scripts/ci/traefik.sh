#!/usr/bin/env bash
# Traefik watches, reads Secrets in and connects to exactly the namespaces with a
# route or a Middleware, and its own: a new app's route can't go unserved, and no
# other namespace's Secrets are readable (infrastructure/controllers/traefik/rbac.yaml).
# Reads what build.sh and render.sh wrote, since a chart can make routes too (Grafana's).
source "$(dirname "$0")/lib.sh"
rendered=${1:?directory build.sh wrote to}
# One namespace per line, sorted. A chart's object may leave its namespace to Helm:
# render.sh names those files helm-<namespace>_<release>.yaml.
namespaces() {
  for f in "$rendered"/*.yaml; do
    ns=
    case "$(basename "$f")" in helm-*)
      ns=$(basename "$f" .yaml)
      ns=${ns#helm-}
      ns=${ns%%_*}
      ;;
    esac
    NS=$ns yq "select(tag == \"!!map\") | $1 | (.metadata.namespace // strenv(NS))" "$f"
  done | grep -v '^---$' | grep -v '^$' | sort -u
}
values() { yq "select(tag == \"!!map\") | $1" "$rendered"/*.yaml | grep -v '^---$' | sort -u; }

want=$({
  namespaces 'select(.kind == "HTTPRoute" or (.kind == "Middleware" and (.apiVersion | test("^traefik.io/"))))'
  echo traefik
} | sort -u)
[ "$(echo "$want" | wc -l)" -gt 1 ] || fail "found no routes: this check is broken"

providers='select(.kind == "HelmRelease" and .metadata.namespace == "traefik" and .metadata.name == "traefik") | .spec.values.providers'
egress='select(.kind == "NetworkPolicy" and .metadata.namespace == "traefik" and .metadata.name == "traefik") | .spec.egress[].to[].namespaceSelector.matchExpressions[]? | select(.key == "kubernetes.io/metadata.name") | .values[]'
compare() { # <what> <namespaces>
  local d
  d=$(diff <(echo "$want") <(echo "$2") | sed -nE 's/^< (.*)/missing \1/p; s/^> (.*)/extra \1/p' | paste -sd, - || true)
  if [ -n "$d" ]; then fail "$1: $d"; else echo "ok   $1"; fi
}
compare "Traefik's kubernetesGateway.namespaces" "$(values "$providers.kubernetesGateway.namespaces[]")"
compare "Traefik's kubernetesCRD.namespaces" "$(values "$providers.kubernetesCRD.namespaces[]")"
compare "RoleBindings to traefik-read-secrets" "$(namespaces 'select(.kind == "RoleBinding" and .roleRef.kind == "ClusterRole" and .roleRef.name == "traefik-read-secrets")')"
compare "Traefik's egress, and its own namespace" "$({
  values "$egress"
  echo traefik
} | sort -u)"
exit $failed
