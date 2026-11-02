#!/usr/bin/env bash
# arr-api.sh <app> <path> [METHOD] [json body] : call an *arr's API from inside
# its pod with the key read there (never printed); compact JSON out.
# e.g. arr-api.sh sonarr /api/v3/downloadclient
set -euo pipefail
app=$1 path=$2 method=${3:-GET} body=${4:-}
case $app in sonarr) port=8989;; radarr) port=7878;; lidarr) port=8686;; prowlarr) port=9696;; *) echo "unknown app" >&2; exit 2;; esac
printf '%s' "$body" | kubectl -n "$app" exec -i deploy/"$app" -- sh -c '
k=$(sed -n "s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p" /config/config.xml)
curl -s -X "$1" -H "X-Api-Key: $k" -H "Content-Type: application/json" --data-binary @- "localhost:$2$3" | jq -c .' _ "$method" "$port" "$path"
