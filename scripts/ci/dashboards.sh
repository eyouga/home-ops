#!/usr/bin/env bash
# The vendored dashboards are exactly what monitoring/dashboards/vendor.sh makes of
# its pinned revisions. Renovate moves only a revision, so its PR goes red here
# until vendor.sh is re-run and its output committed: read that diff first.
source "$(dirname "$0")/lib.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
monitoring/dashboards/vendor.sh "$tmp"
for f in "$tmp"/*.json; do
  name=monitoring/dashboards/$(basename "$f")
  if cmp -s "$f" "$name"; then
    echo "ok   $name"
  else
    fail "$name isn't what vendor.sh makes: run monitoring/dashboards/vendor.sh and commit the result"
  fi
done
exit $failed
