#!/usr/bin/env bash
# home-assistant-rung.sh <version> <digest> : one Home Assistant rung. Compare the
# command with the image's /etc/services.d/home-assistant/run first. Snapshots fast/k8s + fast/k8s-db atomically, bumps the image in
# home-ops, lets Flux roll it (the recorder migrates its schema on start), then
# prints what the start left behind. Any other change for the rung (command,
# env) is staged in the working tree before calling this. Prints no secrets.
set -euo pipefail
ver=$1 digest=$2
cd ~/Code/home-ops; f=apps/home-assistant/release.yaml

ssh 192.168.1.80 "zfs snapshot fast/k8s@pre-home-assistant-$ver fast/k8s-db@pre-home-assistant-$ver"
echo "snapshots pre-home-assistant-$ver"
sed -i '' -E "s#^(              tag: )20[0-9.]+@sha256:[0-9a-f]+#\1$ver@$digest#" $f
git commit -qam "home-assistant: → $ver"
git push -q
flux reconcile ks apps --with-source >/dev/null
flux reconcile hr -n home-assistant home-assistant --timeout=15m >/dev/null
kubectl -n home-assistant rollout status deploy/home-assistant --timeout=15m

echo "== version"; kubectl -n home-assistant exec deploy/home-assistant -- cat /config/.HA_VERSION; echo
echo "== log (WARNING and up, deduplicated)"
kubectl -n home-assistant logs deploy/home-assistant | sed -E 's/\x1b\[[0-9;]*m//g' | grep -E ' (WARNING|ERROR|CRITICAL) ' \
  | grep -v 'recorder.migration' | sed -E 's/^[0-9-]+ [0-9:.]+ //' | cut -c1-230 | sort | uniq -c | sort -rn | head -25
echo "== recorder"
kubectl -n databases exec home-assistant-1 -c postgres -- psql -U postgres -d home-assistant -At -F' ' \
  -c "select 'schema', max(schema_version) from schema_changes;" \
  -c "select 'states', count(*) from states;" \
  -c "select 'statistics', count(*) from statistics;" \
  -c "select 'newest state', to_timestamp(max(last_updated_ts)) from states;"
echo "== http"
curl -s -o /dev/null -w '/ %{http_code}\n' --resolve homeassistant.eyouga.fr:443:192.168.1.201 https://homeassistant.eyouga.fr/
curl -s -o /dev/null -w '/api/ %{http_code}\n' --resolve homeassistant.eyouga.fr:443:192.168.1.201 https://homeassistant.eyouga.fr/api/
