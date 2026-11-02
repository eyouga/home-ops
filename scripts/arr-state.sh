#!/usr/bin/env bash
# arr-state.sh <app> <port> <apiver> (sonarr 8989 v3, radarr 7878 v3, lidarr 8686 v1, prowlarr 9696 v1): version + what the data holds, no secrets
n=$1 p=$2 v=$3
kubectl -n $n exec deploy/$n -- sh -c "k=\$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml)
for e in system/status series movie artist rootfolder downloadclient qualityprofile health; do
  printf '%s\t' \$e; curl -s -H \"X-Api-Key: \$k\" localhost:$p/api/$v/\$e | tr -d '\n'; echo; done" |
python3 -c '
import sys, json
for line in sys.stdin:
    e, _, body = line.rstrip("\n").partition("\t")
    try: d = json.loads(body)
    except Exception: continue
    if e == "system/status": print("version", d["version"], "branch", d.get("branch"))
    elif e in ("series", "movie", "artist"):
        if isinstance(d, list): print(e, len(d), "items, files:", sum((x.get("statistics") or {}).get("episodeFileCount", (x.get("statistics") or {}).get("trackFileCount", 0)) for x in d) if e != "movie" else sum(1 for x in d if x.get("hasFile")))
    elif e == "rootfolder": print(e, [(x["path"], x.get("accessible")) for x in d])
    elif e == "downloadclient": print(e, [(x["name"], x["enable"]) for x in d])
    elif e == "qualityprofile": print(e, [x["name"] for x in d])
    elif e == "health": print(e, [(x["type"], x["message"]) for x in d])
'
