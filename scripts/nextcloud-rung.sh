#!/usr/bin/env bash
# nextcloud-rung.sh <version> <digest> : one Nextcloud rung; set the CronJobs'
# suspend to true in git first, and back after the last rung. Snapshots fast/k8s + fast/k8s-db atomically, bumps the fpm image in
# home-ops (one anchor: app, push, both CronJobs), lets Flux roll it (the
# image's entrypoint copies the code and runs `occ upgrade`), then the
# post-upgrade chores and checks. Prints no secrets.
set -euo pipefail
ver=$1 digest=$2
repo=~/Code/home-ops f=apps/nextcloud/release.yaml
occ() { kubectl -n nextcloud exec deploy/nextcloud -c app -- php occ "$@"; }

ssh 192.168.1.80 "zfs snapshot fast/k8s@pre-nextcloud-$ver fast/k8s-db@pre-nextcloud-$ver"
echo "snapshots pre-nextcloud-$ver"

cd "$repo"
sed -i '' -E "s#^(              tag: )[0-9.]+-fpm@sha256:[0-9a-f]+#\1$ver-fpm@$digest#" $f
git diff --quiet && { echo "tag unchanged" >&2; exit 1; }
git commit -qam "nextcloud: → $ver"
git push -q
flux reconcile ks apps --with-source >/dev/null
flux reconcile hr -n nextcloud nextcloud --timeout=35m >/dev/null
kubectl -n nextcloud rollout status deploy/nextcloud --timeout=35m

echo "== entrypoint"
kubectl -n nextcloud logs deploy/nextcloud -c app | grep -v -E '^\[.*NOTICE' | head -40
echo "== status"; occ status --output=json
# Enabled apps only: --all also updates disabled ones (groupfolders), which
# then fail to boot and fill the log.
echo "== app:update"
for a in $(kubectl -n nextcloud exec deploy/nextcloud -c app -- php occ app:list --enabled --output=json | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["enabled"]))'); do
  occ app:update "$a" 2>&1 | grep -v -E "(up-to-date|^No update|^$)" || true
done
echo "== db"; occ db:add-missing-indices | tail -1; occ db:add-missing-columns | tail -1; occ db:add-missing-primary-keys | tail -1
echo "== repair (mimetypes)"; occ maintenance:repair --include-expensive 2>&1 | grep -i -E "mimetype|error|warn" | head -5 || true
echo "== apps"
kubectl -n nextcloud exec deploy/nextcloud -c app -- sh -c 'php occ app:list --output=json' | python3 -c '
import json, sys; a = json.load(sys.stdin)
print(len(a["enabled"]), "enabled; disabled:", " ".join(sorted(a["disabled"])))
print("non-shipped:", " ".join(f"{k}:{v}" for k, v in sorted(a["enabled"].items()) if k in
  {"announcementcenter","calendar","contacts","impersonate","notify_push","previewgenerator","tasks"}))'
# The push container started notify_push before the entrypoint (and
# app:update above) replaced the app, so it runs the old binary: restart the
# pod (versions now match, so the entrypoint does nothing), then self-test.
kubectl -n nextcloud rollout restart deploy/nextcloud >/dev/null
kubectl -n nextcloud rollout status deploy/nextcloud --timeout=10m >/dev/null
echo "== notify_push"; occ notify_push:self-test 2>&1 | tail -2 || true
echo "== setupchecks"; occ setupchecks 2>&1 | grep -E '✗|⚠|error|warning' | head -20 || true
echo "== log (level >= 3, last 10 min)"
kubectl -n nextcloud exec deploy/nextcloud -c app -- sh -c 'tail -n 400 /var/www/html/data/logs/nextcloud.log 2>/dev/null' | python3 -c '
import json, sys, datetime
# config.php sets logdateformat d/m/Y H:i:s, in local time.
cut = datetime.datetime.now() - datetime.timedelta(minutes=10)
for l in sys.stdin:
    try: e = json.loads(l); t = datetime.datetime.strptime(e["time"], "%d/%m/%Y %H:%M:%S")
    except Exception: continue
    if e.get("level", 0) >= 3 and t >= cut: print(e["time"], e.get("app"), str(e.get("message"))[:200])'
