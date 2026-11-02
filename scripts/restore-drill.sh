#!/usr/bin/env bash
# restore-drill.sh [keep] : rebuild Forgejo from the backups alone, in a throwaway
# namespace, and compare it with the live one. The database comes from the newest
# nightly dump (/srv/backup/dumps), the files from the syncoid replica
# (/srv/backup/fast/k8s/gitea/gitea), both mounted read-only. The live app and its
# database are only read, and the drill can't reach the internet, so its mirrors
# don't pull. Forgejo because it needs both halves to work. Prints counts and
# hashes only, no data and no secrets. With `keep`, leaves it all up to look at.
# The dump is older than the live data, so a few busy tables may differ a little;
# the replica is at most a day behind, so a mirror that pulled since may too.
set -euo pipefail
ns=restore-drill
repo=$(cd "$(dirname "$0")/.." && pwd)
pg_image=$(sed -nE 's/^ *imageName: (.*)$/\1/p' "$repo/apps/gitea/database.yaml")
app_image=codeberg.org/forgejo/forgejo:$(sed -nE 's/^ *tag: (.*-rootless@.*)$/\1/p' "$repo/apps/gitea/release.yaml")

cleanup() {
  kubectl delete ns "$ns" --ignore-not-found --wait=true >/dev/null
  kubectl delete pv restore-drill-dumps restore-drill-gitea --ignore-not-found >/dev/null
}
[ "${1:-}" = keep ] || trap cleanup EXIT

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $ns
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
---
# Only the database takes connections. Its egress stays open (the instance manager
# talks to the API server); the other pods get DNS and the database, nothing else.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: $ns }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: database, namespace: $ns }
spec:
  podSelector:
    matchLabels: { cnpg.io/cluster: restore-gitea }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels: { drill: client }
      ports:
        - { port: 5432, protocol: TCP }
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: cnpg-system }
      ports:
        - { port: 8000, protocol: TCP }
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: clients, namespace: $ns }
spec:
  podSelector:
    matchLabels: { drill: client }
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: kube-system }
          podSelector:
            matchLabels: { k8s-app: kube-dns }
      ports:
        - { port: 53, protocol: UDP }
        - { port: 53, protocol: TCP }
    - to:
        - podSelector:
            matchLabels: { cnpg.io/cluster: restore-gitea }
      ports:
        - { port: 5432, protocol: TCP }
---
# local-path, not fast: its Delete policy clears the volume with the namespace.
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: { name: restore-gitea, namespace: $ns }
spec:
  instances: 1
  imageName: $pg_image
  storage: { storageClass: local-path, size: 5Gi }
  bootstrap:
    initdb: { database: gitea, owner: gitea }
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: restore-drill-dumps }
spec:
  capacity: { storage: 50Gi }
  accessModes: [ReadOnlyMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef: { namespace: $ns, name: dumps }
  hostPath: { path: /srv/backup/dumps, type: Directory }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: dumps, namespace: $ns }
spec:
  accessModes: [ReadOnlyMany]
  storageClassName: ""
  volumeName: restore-drill-dumps
  resources: { requests: { storage: 50Gi } }
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: restore-drill-gitea }
spec:
  capacity: { storage: 5Gi }
  accessModes: [ReadOnlyMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef: { namespace: $ns, name: replica }
  hostPath: { path: /srv/backup/fast/k8s/gitea/gitea, type: Directory }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: replica, namespace: $ns }
spec:
  accessModes: [ReadOnlyMany]
  storageClassName: ""
  volumeName: restore-drill-gitea
  resources: { requests: { storage: 5Gi } }
EOF

kubectl -n "$ns" wait "cluster.postgresql.cnpg.io/restore-gitea" --for=condition=Ready --timeout=300s >/dev/null
echo "empty cluster up"

kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: { name: pg-restore, namespace: $ns }
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: { drill: client }
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 26
        runAsGroup: 26
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: restore
          image: $pg_image
          command:
            - /bin/bash
            - -c
            - |
              set -euo pipefail
              # kube-router admits a new pod about a second after it starts.
              until pg_isready -q; do sleep 1; done
              dump=\$(ls -1r /dumps/gitea/gitea-*.dump | head -1)
              echo "restoring \$dump"
              pg_restore --single-transaction --exit-on-error -d gitea "\$dump"
          env:
            - { name: PGHOST, value: restore-gitea-rw }
            - { name: PGSSLMODE, value: require }
            - name: PGUSER
              valueFrom:
                secretKeyRef: { name: restore-gitea-app, key: username }
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef: { name: restore-gitea-app, key: password }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: dumps, mountPath: /dumps, readOnly: true }
      volumes:
        - name: dumps
          persistentVolumeClaim: { claimName: dumps, readOnly: true }
EOF
kubectl -n "$ns" wait job/pg-restore --for=condition=Complete --timeout=300s >/dev/null \
  || { kubectl -n "$ns" logs job/pg-restore | tail -20; exit 1; }
kubectl -n "$ns" logs job/pg-restore | grep restoring

counts() { # <namespace> <pod>
  local q="select format('select %L, count(*) from %I.%I;', schemaname||'.'||tablename, schemaname, tablename) from pg_tables where schemaname not in ('pg_catalog','information_schema') order by 1"
  kubectl -n "$1" exec -i "$2" -c postgres -- psql -U postgres -d gitea -At -c "$q" \
    | kubectl -n "$1" exec -i "$2" -c postgres -- psql -U postgres -d gitea -At -F' ' | sort
}
tmp=$(mktemp -d)
counts databases gitea-1 >"$tmp/live"
counts "$ns" restore-gitea-1 >"$tmp/restored"
echo "live:     $(wc -l <"$tmp/live") tables, $(awk '{s+=$2} END {print s}' "$tmp/live") rows"
echo "restored: $(wc -l <"$tmp/restored") tables, $(awk '{s+=$2} END {print s}' "$tmp/restored") rows"
diff "$tmp/live" "$tmp/restored" && echo "every table's row count identical" || true

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: forgejo
  namespace: $ns
  labels: { drill: client }
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  initContainers:
    - name: copy
      image: $app_image
      command: [cp, -a, /replica/., /data/]
      securityContext: &security
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      volumeMounts:
        - { name: replica, mountPath: /replica, readOnly: true }
        - { name: data, mountPath: /data }
  containers:
    - name: app
      image: $app_image
      # The same as apps/gitea/release.yaml, but for the database.
      env:
        - { name: TZ, value: Europe/Paris }
        - { name: GITEA_WORK_DIR, value: /data }
        - { name: GITEA_CUSTOM, value: /data/gitea }
        - { name: GITEA_APP_INI, value: /data/gitea/conf/app.ini }
        - { name: FORGEJO_WORK_DIR, value: /data }
        - { name: FORGEJO_CUSTOM, value: /data/gitea }
        - { name: FORGEJO_APP_INI, value: /data/gitea/conf/app.ini }
        - { name: GITEA_TEMP, value: /tmp/gitea }
        - { name: TMPDIR, value: /tmp/gitea }
        - { name: GNUPGHOME, value: /data/git/.gnupg }
        - { name: GITEA__database__HOST, value: "restore-gitea-rw:5432" }
        - { name: GITEA__cache__ADAPTER, value: memory }
        - { name: GITEA__cache__HOST, value: "" }
        - name: GITEA__database__PASSWD
          valueFrom:
            secretKeyRef: { name: restore-gitea-app, key: password }
      readinessProbe:
        httpGet: { path: /api/healthz, port: 3000 }
        periodSeconds: 5
        failureThreshold: 60
      resources:
        requests: { cpu: 50m, memory: 256Mi }
        limits: { memory: 1Gi }
      securityContext: *security
      volumeMounts:
        - { name: data, mountPath: /data }
        - { name: varlib, mountPath: /var/lib/gitea }
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: replica
      persistentVolumeClaim: { claimName: replica, readOnly: true }
    - { name: data, emptyDir: {} }
    - { name: varlib, emptyDir: {} }
    - { name: tmp, emptyDir: {} }
EOF
kubectl -n "$ns" wait pod/forgejo --for=condition=Ready --timeout=300s >/dev/null \
  || { kubectl -n "$ns" logs pod/forgejo -c app --tail=30; exit 1; }
echo "Forgejo up on the restored data"

fj() { kubectl -n "$ns" exec pod/forgejo -c app -- "$@"; }
sql="select (select count(*) from repository), (select count(*) from \"user\"), (select count(*) from mirror)"
echo "repos, users, mirrors in the restored DB: $(kubectl -n "$ns" exec restore-gitea-1 -c postgres -- psql -U postgres -d gitea -At -c "$sql")"
echo "API lists: $(fj curl -fsS -o /dev/null -D - 'http://127.0.0.1:3000/api/v1/repos/search' | tr -d '\r' | awk 'tolower($1)=="x-total-count:" {print $2}') public repos"

# Each repository: fsck on the restored copy, and its refs against the live one's.
# find, not a glob: */*.git would skip a repo named .dotfiles.git.
list='cd /data/git/gitea-repositories && find . -mindepth 2 -maxdepth 2 -name "*.git" -type d | sort'
refs="$list"' | while read -r r; do echo "$r $(git -C "$r" for-each-ref | sha256sum | cut -c1-16)"; done'
fj sh -c "$refs" | sort >"$tmp/restored-refs"
kubectl -n gitea exec deploy/gitea -c app -- sh -c "$refs" | sort >"$tmp/live-refs"
fj sh -c "$list"' | while read -r r; do git -C "$r" fsck --no-progress >/dev/null 2>&1 && echo "fsck ok: $r" || echo "FSCK FAILED: $r"; done'
diff "$tmp/live-refs" "$tmp/restored-refs" && echo "every repo's refs identical to live" || true

# Each repo served over HTTP, from a clone of the restored copy.
fj sh -c 'cd /tmp && for u in $(curl -fsS "http://127.0.0.1:3000/api/v1/repos/search?limit=50" | grep -oE "\"clone_url\":\"[^\"]*\"" | cut -d\" -f4 | sed -E "s#^https?://[^/]+#http://127.0.0.1:3000#"); do
  git clone -q --mirror "$u" /tmp/clone.git 2>/dev/null && echo "clone ok: ${u##*/}, $(git -C /tmp/clone.git rev-list --all --count) commits" || echo "CLONE FAILED: $u"
  rm -rf /tmp/clone.git
done'

echo 'doctor, every line that is not fine ("Garbage collect LFS" always says ERROR: LFS is off):'
fj forgejo doctor check --all 2>&1 | grep -E 'ERROR|FAIL|fatal' | cut -c1-120 || echo none
rm -rf "$tmp"
