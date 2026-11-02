#!/bin/bash
# One logical dump of $CLUSTER (database and role share its name) into
# /dumps/$CLUSTER/, keeping the newest $KEEP. Any failure fails the job, which
# fires KubeJobFailed → ntfy, and removes nothing: only a dump that reads back
# as an archive with tables counts, and only then does an old one go.
set -euo pipefail
umask 077

export PGHOST="$CLUSTER-rw.databases.svc" PGDATABASE="$CLUSTER" PGSSLMODE=require PGCONNECT_TIMEOUT=5
KEEP=14
dir="/dumps/$CLUSTER"
dump="$dir/$CLUSTER-$(date -u +%Y%m%dT%H%M%SZ).dump"

# kube-router admits a new pod about a second after it starts, and the database
# may be restarting. Two minutes, then this run has failed.
for _ in $(seq 60); do
  pg_isready -q && break
  sleep 2
done
pg_isready

mkdir -p "$dir"
trap 'rm -f "$dump.partial"' EXIT
pg_dump --format=custom --file="$dump.partial"
tables=$(pg_restore --list "$dump.partial" | grep -c ' TABLE DATA ')
[ "$tables" -gt 0 ]
mv "$dump.partial" "$dump"
echo "$dump: $(du -h --apparent-size "$dump" | cut -f1), $tables tables"

# By count, never by age: if dumps stop, the last good ones stay. Timestamps
# sort by name, so reversed means newest first.
ls -1r "$dir"/"$CLUSTER"-*.dump | tail -n "+$((KEEP + 1))" | xargs -r rm -v --
