#!/usr/bin/env bash
# rollback.sh <app> [--revert <sha>] [--before "<date>" | --snapshot <name>] [--with-files] [--yes]
#
# MIGRATION.md §10's fallback: an upgrade went wrong and its migrations won't undo
# themselves. Puts <app>'s volumes and database back as they were before a commit, then
# reverts that commit. <app> is the namespace (Forgejo's is `gitea`). Without --yes it
# only prints the plan, and nothing changes: READ IT, this replaces live data with older data.
#
# What goes back: every PV under /var/lib/k8s-volumes/<app>/ (fast/k8s), and the CNPG
# cluster <app> in `databases` if there is one (fast/k8s-db). Whatever changed there since
# the snapshot is lost, apart from the pre-rollback snapshot this takes first.
# Never touched: /srv/data, and tank/nextcloud unless --with-files.
#
# Nextcloud's files stay by default, on purpose: an upgrade doesn't change them, and copying
# them back would delete what people uploaded since. occ files:scan then makes the
# database agree with the disk. --with-files is for damaged files: it takes tank/nextcloud back
# too, losing those uploads, shows what would change and asks, and needs your sudo.
#
# The copy runs as a pod under the volume's own uid, so nothing here needs root but
# --with-files. On a failure it stops where it is, app down: see the message.
set -euo pipefail
host=192.168.1.80
repo=$(cd "$(dirname "$0")/.." && pwd)
root=/var/lib/k8s-volumes
jobns=rollback-restore
ts=$(date +%Y%m%d-%H%M%S)

app=${1:?usage: rollback.sh <app> [--revert <sha>] [--before <date> | --snapshot <name>] [--with-files] [--yes]}
shift
sha="" before="" snapshot="" with_files="" yes=""
while [ $# -gt 0 ]; do
  case "$1" in
    --revert) sha=$2; shift 2 ;;
    --before) before=$2; shift 2 ;;
    --snapshot) snapshot=$2; shift 2 ;;
    --with-files) with_files=1; shift ;;
    --yes) yes=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
die() { echo "rollback: $*" >&2; exit 1; }
say() { echo "== $*"; }
[[ $app =~ ^[a-z0-9-]+$ ]] || die "bad app name"
[ -z "$with_files" ] || [ "$app" = nextcloud ] || die "--with-files is Nextcloud's alone"
kubectl -n "$app" get helmrelease "$app" >/dev/null 2>&1 || die "no HelmRelease $app in namespace $app"

# What the app has, from the cluster itself, so a new app needs no table here.
pv_paths() { # <namespace>: the host paths of its volumes
  kubectl get pv -o go-template='{{range .items}}{{if .spec.claimRef}}{{if eq .spec.claimRef.namespace "'"$1"'"}}{{.spec.hostPath.path}}{{"\n"}}{{end}}{{end}}{{end}}' | sort -u
}
volumes=()
while read -r path; do
  if [[ $path =~ ^$root/$app/[a-zA-Z0-9._-]+$ ]]; then volumes+=("$path"); fi
done < <(pv_paths "$app")
cluster=""
if kubectl -n databases get cluster "$app" >/dev/null 2>&1; then
  [ "$(kubectl -n databases get cluster "$app" -o jsonpath='{.spec.instances}')" = 1 ] || die "cluster $app has more than one instance"
  cluster=$app
  [ -n "$(pv_paths databases | grep -xF "$root/databases/$cluster-1")" ] || die "$cluster's volume isn't at $root/databases/$cluster-1"
fi
[ "${#volumes[@]}" -gt 0 ] || [ -n "$cluster" ] || die "$app has nothing on fast/ to restore"

# The commit to undo says when: the last snapshot before it.
if [ -n "$sha" ]; then
  git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || die "no commit $sha"
  [ -n "$before" ] || before=@$(git -C "$repo" show -s --format=%ct "$sha")
fi
[ -n "$snapshot" ] || [ -n "$before" ] || die "say which point: --revert <sha>, --before <date> or --snapshot <name>"
if [ -n "$before" ]; then
  cutoff=$(python3 -c 'import sys,subprocess,datetime as d
s=sys.argv[1]
print(s[1:] if s.startswith("@") else int(d.datetime.fromisoformat(s).timestamp()))' "$before")
fi
# `pre-rollback-*` is this script's own, syncoid_* sits on the replicas' schedule.
pick() { # <dataset>: the snapshot to use on it
  if [ -n "$snapshot" ]; then
    ssh "$host" zfs list -H -o name "$1@$snapshot" >/dev/null 2>&1 || die "no snapshot $1@$snapshot"
    echo "$snapshot"
  else
    local name
    name=$(ssh "$host" zfs list -Hp -t snapshot -o name,creation -s creation "$1" \
      | awk -v t="$cutoff" -F'\t' '$2 < t { print $1 }' | { grep -vE '@(syncoid_|pre-rollback-)' || true; } | tail -1 | cut -d@ -f2)
    [ -n "$name" ] || die "no snapshot of $1 before that point"
    echo "$name"
  fi
}
snap_k8s=$(pick fast/k8s)
[ -z "$cluster" ] || snap_db=$(pick fast/k8s-db)
[ -z "$with_files" ] || snap_files=$(pick tank/nextcloud)

# Live path and its copy in the snapshot, one pair per line.
pairs=()
for v in "${volumes[@]+"${volumes[@]}"}"; do
  pairs+=("$v $root/.zfs/snapshot/$snap_k8s/${v#"$root"/}")
done
[ -z "$cluster" ] || pairs+=("$root/databases/$cluster-1 $root/databases/.zfs/snapshot/$snap_db/$cluster-1")

# What to start again. A run that failed left everything at 0: it noted the real
# values on the objects, so running this again still knows them.
workloads=$(kubectl -n "$app" get deploy,statefulset -o go-template='{{range .items}}{{.kind}}/{{.metadata.name}} {{with index .metadata.annotations "rollback.eyouga.fr/replicas"}}{{.}}{{else}}{{.spec.replicas}}{{end}}{{"\n"}}{{end}}')
crons=$(kubectl -n "$app" get cronjob -o go-template='{{range .items}}{{.metadata.name}} {{with index .metadata.annotations "rollback.eyouga.fr/suspend"}}{{.}}{{else}}{{.spec.suspend}}{{end}}{{"\n"}}{{end}}')

say "Plan for $app, nothing has changed yet"
echo "  safety snapshot  fast/k8s@pre-rollback-$app-$ts fast/k8s-db@pre-rollback-$app-$ts"
echo "  stop             HelmRelease $app suspended; to 0:" $(echo "$workloads" | cut -d' ' -f1); [ -z "$cluster" ] || echo "                   database $cluster hibernated"
for p in "${pairs[@]}"; do
  echo "  REPLACE          ${p%% *}"
  echo "    with           ${p##* }"
done
if [ "$app" = nextcloud ]; then
  if [ -n "$with_files" ]; then
    echo "  REPLACE          /srv/nextcloud with tank/nextcloud@$snap_files, asks first, with sudo"
  else
    echo "  keep             tank/nextcloud (/srv/nextcloud): files stay, then occ files:scan --all"
  fi
fi
[ -z "$sha" ] || echo "  revert           $(git -C "$repo" log -1 --format='%h %s' "$sha" | cut -c1-90)"
echo "  start            database, then Flux, then the workloads at their replicas"
if [ -z "$yes" ]; then
  echo; echo "Plan only. Add --yes to do it."
  exit 0
fi

step="taking the safety snapshot"
started=""
on_exit() {
  [ "$?" != 0 ] || return 0
  echo >&2
  echo "rollback: FAILED while $step." >&2
  if [ -n "$started" ]; then
    echo "  The app stays down: HelmRelease $app is suspended and its workloads are at 0." >&2
    [ -z "$cluster" ] || echo "  Database $cluster may be hibernated: kubectl -n databases annotate cluster $cluster cnpg.io/hibernation=off --overwrite" >&2
    echo "  What was live is in fast/k8s@pre-rollback-$app-$ts and fast/k8s-db@pre-rollback-$app-$ts; $jobns's pods are left to read." >&2
    echo "  Fix the cause and run this again: it's safe, and knows the replicas." >&2
  fi
}
trap on_exit EXIT

say "$step"
ssh "$host" "zfs snapshot fast/k8s@pre-rollback-$app-$ts fast/k8s-db@pre-rollback-$app-$ts"
started=1

step="stopping the app"; say "$step"
flux suspend hr -n "$app" "$app" >/dev/null
while read -r name suspended; do
  [ -n "$name" ] || continue
  kubectl -n "$app" annotate cronjob "$name" "rollback.eyouga.fr/suspend=${suspended:-false}" --overwrite >/dev/null
  [ "$suspended" = true ] || kubectl -n "$app" patch cronjob "$name" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
done <<<"$crons"
kubectl -n "$app" get job -o name | xargs -r kubectl -n "$app" delete --wait=true >/dev/null
while read -r name replicas; do
  [ -n "$name" ] || continue
  kubectl -n "$app" annotate "$name" "rollback.eyouga.fr/replicas=$replicas" --overwrite >/dev/null
  kubectl -n "$app" scale "$name" --replicas=0 >/dev/null
done <<<"$workloads"
kubectl -n "$app" wait --for=delete pod --all --timeout=5m >/dev/null 2>&1 || [ -z "$(kubectl -n "$app" get pod -o name)" ]
if [ -n "$cluster" ]; then
  kubectl -n databases annotate cluster "$cluster" cnpg.io/hibernation=on --overwrite >/dev/null
  kubectl -n databases wait --for=delete pod -l "cnpg.io/cluster=$cluster" --timeout=5m >/dev/null 2>&1 || [ -z "$(kubectl -n databases get pod -l "cnpg.io/cluster=$cluster" -o name)" ]
fi

# Same image as the databases: pinned, on the node already, with GNU cp and find (MIGRATION.md §13).
image=$(sed -nE 's/^ *imageName: (.*)$/\1/p' "$repo/apps/gitea/database.yaml")
cleanup_restore() {
  kubectl delete ns "$jobns" --ignore-not-found --wait=true >/dev/null
  kubectl get pv -o name | { grep -E '^persistentvolume/rollback-(live|snap)-[0-9]+$' || true; } | xargs -r kubectl delete >/dev/null
}
step="preparing the copy"; say "$step"
cleanup_restore
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $jobns
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-all, namespace: $jobns }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
YAML

# <kind> <i> <path>: a PV on that path and its claim. Retain: removing it leaves the files alone.
volume() {
  local mode=ReadWriteOnce
  [ "$1" = live ] || mode=ReadOnlyMany
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: PersistentVolume
metadata: { name: rollback-$1-$2 }
spec:
  capacity: { storage: 1Ti }
  accessModes: [$mode]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef: { namespace: $jobns, name: $1-$2 }
  hostPath: { path: "$3", type: Directory }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $1-$2, namespace: $jobns }
spec:
  accessModes: [$mode]
  storageClassName: ""
  volumeName: rollback-$1-$2
  resources: { requests: { storage: 1Ti } }
YAML
}
# <name> <uid> <i> <with live?> <script>: one pod, its logs to stdout, fails if it does.
run() {
  local mounts='[{"name":"snap","mountPath":"/snapshot","readOnly":true}]' vols='[{"name":"snap","persistentVolumeClaim":{"claimName":"snap-'"$3"'","readOnly":true}}]'
  if [ "$4" = 1 ]; then
    mounts='[{"name":"snap","mountPath":"/snapshot","readOnly":true},{"name":"live","mountPath":"/live"}]'
    vols='[{"name":"snap","persistentVolumeClaim":{"claimName":"snap-'"$3"'","readOnly":true}},{"name":"live","persistentVolumeClaim":{"claimName":"live-'"$3"'"}}]'
  fi
  python3 -c 'import json,sys
name,uid,image,mounts,vols,script=sys.argv[1:7]
print(json.dumps({"apiVersion":"v1","kind":"Pod","metadata":{"name":name,"namespace":"'"$jobns"'"},
 "spec":{"restartPolicy":"Never","securityContext":{"runAsNonRoot":True,"runAsUser":int(uid),"runAsGroup":int(uid),"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":"copy","image":image,"command":["bash","-c",script],"volumeMounts":json.loads(mounts),
  "securityContext":{"allowPrivilegeEscalation":False,"capabilities":{"drop":["ALL"]}}}],"volumes":json.loads(vols)}}))' \
    "$1" "$2" "$image" "$mounts" "$vols" "$5" | kubectl apply -f - >/dev/null
  local phase="" waited=0
  while :; do
    phase=$(kubectl -n "$jobns" get pod "$1" -o jsonpath='{.status.phase}')
    case "$phase" in Succeeded | Failed) break ;; esac
    # Still Pending by then, it can't mount: the snapshot doesn't hold this volume.
    if [ "$phase" = Pending ] && [ "$waited" -ge 120 ]; then
      kubectl -n "$jobns" get events --field-selector "involvedObject.name=$1" -o go-template='{{range .items}}  {{.reason}}: {{.message}}{{"\n"}}{{end}}' | tail -2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  kubectl -n "$jobns" logs "$1"
  [ "$phase" = Succeeded ]
}

# The refusals come first, before the delete: an empty snapshot, files this uid can't keep.
copy_script='set -euo pipefail
[ -n "$(ls -A /snapshot)" ] || { echo "the snapshot is empty"; exit 3; }
foreign=$(find /snapshot -mindepth 1 ! -uid "$(id -u)" | wc -l)
[ "$foreign" = 0 ] || { echo "$foreign entries belong to another uid: this pod would change their owner"; exit 4; }
find /live -mindepth 1 -delete
# The contents, not the top directory: that belongs to root, and this pod does not.
find /snapshot -mindepth 1 -maxdepth 1 -exec cp -a -t /live {} +
different=$(diff -rq --no-dereference /snapshot /live | wc -l)
[ "$different" = 0 ] || { echo "$different entries differ after the copy"; exit 5; }
echo "  $(find /live | wc -l) entries, $(du -sh /live | cut -f1), identical to the snapshot"'

i=0
for p in "${pairs[@]}"; do
  i=$((i + 1)); live=${p%% *}; from=${p##* }
  step="copying back $live"; say "$step"
  volume live "$i" "$live"
  volume snap "$i" "$from"
  # Who owns what's in it is who the app writes as. The top directory is the provisioner's.
  uid=$(run "owner-$i" 65534 "$i" 0 "find /snapshot -mindepth 1 -maxdepth 1 -printf '%U\n' | grep -vx 0 | sort | uniq -c | sort -rn | sed -n '1s/.* //p'" | tail -1)
  [[ $uid =~ ^[1-9][0-9]*$ ]] || { step="reading the owner of $from: '$uid'"; false; }
  run "copy-$i" "$uid" "$i" 1 "$copy_script"
done

if [ -n "$with_files" ]; then
  step="taking /srv/nextcloud back to $snap_files"; say "$step"
  src=/srv/nextcloud/.zfs/snapshot/$snap_files/
  echo "  sudo will ask for your password on def-jam. Counting what would change..."
  ssh -t "$host" "sudo rsync -aHAXn --delete --stats $src /srv/nextcloud/ | grep -E 'Number of (regular files transferred|deleted files)|Total transferred'"
  read -r -p "  Those files are overwritten or deleted, for good once snapshots age out. Type yes to go on: " answer
  if [ "$answer" != yes ]; then
    step="asking about the files (you said no); fast/ is already rolled back. Start it by hand, or re-run without --with-files"
    false
  fi
  ssh -t "$host" "sudo zfs snapshot tank/nextcloud@pre-rollback-$app-$ts && sudo rsync -aHAX --delete $src /srv/nextcloud/"
fi
cleanup_restore

if [ -n "$cluster" ]; then
  step="starting the database"; say "$step"
  kubectl -n databases annotate cluster "$cluster" cnpg.io/hibernation=off --overwrite >/dev/null
  sleep 5
  kubectl -n databases wait cluster "$cluster" --for=condition=Ready --timeout=10m >/dev/null
fi

if [ -n "$sha" ]; then
  step="reverting $sha"; say "$step"
  git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet || die "$repo has uncommitted changes: revert $sha by hand, then flux resume hr -n $app $app and scale back"
  [ "$(git -C "$repo" symbolic-ref --short HEAD)" = main ] || die "$repo isn't on main: revert $sha by hand"
  git -C "$repo" pull -q --ff-only
  git -C "$repo" revert --no-edit "$sha" >/dev/null
  git -C "$repo" push -q
  flux reconcile source git flux-system >/dev/null
  # Applies the reverted HelmRelease, still suspended, so nothing can start the bad version.
  flux reconcile ks apps --timeout=5m >/dev/null || echo "  (the apps layer reports not Ready while $app is down; going on)"
fi

step="starting the app"; say "$step"
# A migration can outlast the release's timeout; the scale-up below still has to happen.
flux resume hr -n "$app" "$app" --timeout=35m >/dev/null || echo "  (HelmRelease not Ready yet, going on: check it)"
while read -r name replicas; do
  [ -n "$name" ] || continue
  kubectl -n "$app" scale "$name" --replicas="$replicas" >/dev/null
  kubectl -n "$app" annotate "$name" rollback.eyouga.fr/replicas- >/dev/null
done <<<"$workloads"
while read -r name suspended; do
  [ -n "$name" ] || continue
  [ "$suspended" = true ] || kubectl -n "$app" patch cronjob "$name" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null
  kubectl -n "$app" annotate cronjob "$name" rollback.eyouga.fr/suspend- >/dev/null
done <<<"$crons"
while read -r name _; do
  [ -z "$name" ] || kubectl -n "$app" rollout status "$name" --timeout=20m >/dev/null
done <<<"$workloads"

if [ "$app" = nextcloud ]; then
  step="making Nextcloud's database agree with its files"; say "$step"
  occ() { kubectl -n nextcloud exec deploy/nextcloud -c app -- php occ "$@"; }
  occ status --output=json | python3 -c 'import json,sys; s=json.load(sys.stdin); print("  ", {k: s[k] for k in ("installed","versionstring","maintenance","needsDbUpgrade")})'
  # A file uploaded since the snapshot is on disk but not in the database, and the
  # other way around: the scan settles both. The fingerprint tells sync clients the
  # server went back in time, so they re-check instead of trusting what they know.
  occ files:scan --all --no-interaction | tail -3
  occ maintenance:data-fingerprint
fi
trap - EXIT

say "Done"
echo "  Check: kubectl -n $app get pods; flux get hr -n $app"
echo "  What was live before this: fast/k8s@pre-rollback-$app-$ts fast/k8s-db@pre-rollback-$app-$ts; sudo zfs destroy them when sure."
[ -z "$sha" ] || echo "  Renovate will offer this update again, as a PR that doesn't automerge: close it, or fix what broke."
