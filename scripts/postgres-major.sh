#!/usr/bin/env bash
# postgres-major.sh <cluster> <image-tag@digest> : one CNPG cluster to a new
# Postgres major, in place (pg_upgrade --link, triggered by the image change).
# The app (same name as its namespace and Deployment; gitea, home-assistant,
# nextcloud) is stopped first, so exact row counts before and after can be
# compared. Dump to ~/def-jam-rescue/dumps + fast/k8s-db snapshot before. If the
# upgrade job fails: revert the image in git, CNPG goes back to the old major.
# Prints counts and hashes only, no data and no secrets.
set -euo pipefail
c=$1 image=$2 major=${2%%.*}
repo=~/Code/home-ops f=apps/$c/database.yaml
tmp=$(mktemp -d)
psql_() { kubectl -n databases exec -i "$c-1" -c postgres -- psql -U postgres -At "$@"; }
counts() {
  psql_ -d "$c" -c "select format('select %L, count(*) from %I.%I;', schemaname||'.'||tablename, schemaname, tablename) from pg_tables where schemaname not in ('pg_catalog','information_schema') order by 1" \
    | psql_ -d "$c" -F' ' | sort
}

flux suspend hr -n "$c" "$c" >/dev/null
kubectl -n "$c" scale "deploy/$c" --replicas=0 >/dev/null
kubectl -n "$c" wait pod -l "app.kubernetes.io/name=$c,app.kubernetes.io/controller=$c" --for=delete --timeout=180s >/dev/null || true
echo "app stopped"

mkdir -p ~/def-jam-rescue/dumps
kubectl -n databases exec "$c-1" -c postgres -- pg_dump -U postgres -Fc "$c" > ~/def-jam-rescue/dumps/"$c"-pre-pg"$major".dump
echo "dump $(du -h ~/def-jam-rescue/dumps/"$c"-pre-pg"$major".dump | cut -f1)"
counts > "$tmp/before"
echo "before: $(wc -l < "$tmp/before") tables, $(awk '{s+=$2} END {print s}' "$tmp/before") rows, $(psql_ -c 'show server_version')"
ssh 192.168.1.80 "zfs snapshot fast/k8s-db@pre-pg$major-$c"

cd "$repo"
sed -i '' -E "s#(imageName: ghcr.io/cloudnative-pg/postgresql:)[^ ]+#\1$image#" "$f"
git commit -qam "$c: Postgres → $major (CNPG in-place major upgrade)"
git push -q
flux reconcile ks apps --with-source >/dev/null || true

# Ready is still true until the operator acts, so wait for the new major itself.
for _ in $(seq 1 120); do
  v=$(kubectl -n databases exec "$c-1" -c postgres -- psql -U postgres -At -c 'show server_version_num' 2>/dev/null || true)
  [ "${v:-0}" -ge "${major}0000" ] && break
  sleep 10
done
[ "${v:-0}" -ge "${major}0000" ] || { echo "NOT UPGRADED after 20 min; app left stopped"; kubectl -n databases get pods; exit 1; }
kubectl -n databases wait "cluster.postgresql.cnpg.io/$c" --for=condition=Ready --timeout=300s >/dev/null

counts > "$tmp/after"
echo "after:  $(wc -l < "$tmp/after") tables, $(awk '{s+=$2} END {print s}' "$tmp/after") rows, $(psql_ -c 'show server_version')"
if diff "$tmp/before" "$tmp/after" >/dev/null; then echo "every table's row count identical"; else echo "COUNTS DIFFER; app left stopped"; diff "$tmp/before" "$tmp/after" | head -20; exit 1; fi

# pg_upgrade doesn't carry optimizer statistics over.
kubectl -n databases exec "$c-1" -c postgres -- vacuumdb -U postgres --all --analyze-only 2>&1 | tail -1

flux resume hr -n "$c" "$c" >/dev/null
kubectl -n "$c" scale "deploy/$c" --replicas=1 >/dev/null
kubectl -n "$c" rollout status "deploy/$c" --timeout=15m
rm -rf "$tmp"
