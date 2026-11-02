#!/usr/bin/env bash
# Every route has a blackbox target and every target a route, so a new app can't
# quietly go unwatched (monitoring/blackbox-exporter.yaml). Reads what build.sh and
# render.sh wrote, since a chart can make routes too (Grafana's).
source "$(dirname "$0")/lib.sh"
rendered=${1:?directory build.sh wrote to}
routes=$(yq 'select(tag == "!!map" and .kind == "HTTPRoute") | .spec.hostnames[]' "$rendered"/*.yaml | grep -v '^---$' | sort -u)
targets=$(yq '.spec.values.serviceMonitor.targets[].url' monitoring/blackbox-exporter.yaml | sed -E 's#^https://([^/]+)/.*#\1#' | sort -u)
[ -n "$routes" ] && [ -n "$targets" ] || fail "found no routes or no targets: this check is broken"
for h in $(comm -23 <(echo "$routes") <(echo "$targets")); do fail "route $h has no blackbox target"; done
for h in $(comm -13 <(echo "$routes") <(echo "$targets")); do fail "blackbox target $h has no route"; done
echo "$(echo "$routes" | wc -l) routes, all probed"
exit $failed
