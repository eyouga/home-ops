#!/usr/bin/env bash
# jellyfin-state.sh <label>: copy Jellyfin's DBs out of the pod (online backup API of
# sqlite isn't available there, so a plain copy, WAL included), print counts.
set -euo pipefail
d=${TMPDIR:-/tmp}/jf-$1; rm -rf "$d"; mkdir -p "$d"
pod=$(kubectl -n jellyfin get pod -l app.kubernetes.io/name=jellyfin -o name | head -1)
for f in $(kubectl -n jellyfin exec "${pod#pod/}" -- sh -c 'cd /config/data && ls *.db *.db-wal *.db-shm 2>/dev/null'); do
  kubectl -n jellyfin exec "${pod#pod/}" -- cat "/config/data/$f" > "$d/$f"
done
python3 - "$d" <<'PY'
import sqlite3, sys, os
d = sys.argv[1]
names = set(os.listdir(d)); print("files:", sorted(n for n in names if n.endswith(".db")))
c = sqlite3.connect(f"file:{d}/jellyfin.db?", uri=True)
tables = {r[0] for r in c.execute("select name from sqlite_master where type='table'")}
if "BaseItems" in tables:   # 10.11+: everything in jellyfin.db (EF Core)
    q = lambda s: c.execute(s).fetchall()
    print("items:", q("select Type, count(*) from BaseItems where Type like '%Movie' or Type like '%Episode' or Type like '%Series' or Type like '%Audio' or Type like '%MusicAlbum' group by Type"))
    print("played:", q("select count(*) from UserData where Played = 1"), "with position:", q("select count(*) from UserData where PlaybackPositionTicks > 0"))
    print("paths not under /media:", q("select count(*) from BaseItems where Path is not null and Path like '/%' and Path not like '/media/%' and Path not like '/config/%' and Path not like '%/metadata/%'"))
else:                       # 10.9/10.10: library.db holds the items
    l = sqlite3.connect(f"file:{d}/library.db?", uri=True); q = lambda s: l.execute(s).fetchall()
    print("items:", q("select type, count(*) from TypedBaseItems where type like '%Movie' or type like '%Episode' or type like '%Series' or type like '%Audio' or type like '%MusicAlbum' group by type"))
    print("played:", q("select count(*) from UserDatas where played = 1"), "with position:", q("select count(*) from UserDatas where playbackPositionTicks > 0"))
    print("paths not under /media:", q("select count(*) from TypedBaseItems where path is not null and path like '/%' and path not like '/media/%' and path not like '/config/%' and path not like '%/metadata/%'"))
print("users:", c.execute("select count(*) from Users").fetchall())
PY
