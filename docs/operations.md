# Operations

## Upgrades

Renovate opens the updates (`.github/renovate.json5`, whose comments say why each
rule exists). In short: patches and digests of a few apps merge on their own after
three days with every check green, between 09:00 and 19:00; CI's own tooling merges
when green; everything else is a pull request for a person. Majors that need a
procedure (Nextcloud, Forgejo, Postgres, Home Assistant's jumps,
kube-prometheus-stack with its CRDs) are **draft** pull requests labelled `rung`,
never merged as they are: the body names the script below.

No HelmRelease has `remediation`: rolling back to an old binary on a migrated
database is the failure to avoid. A failed upgrade stops where it is, keeps its
state, and `FluxObjectNotReady` reaches the phone.

**By hand, one rung at a time:**

1. Find the **latest** release, not the next one you expect, and read its notes
   for required stops.
2. Snapshot the app's volumes:
   `zfs snapshot fast/k8s@pre-<app>-<ver> fast/k8s-db@pre-<app>-<ver>` on def-jam
   (no sudo needed for these two datasets). Stop the app first if the notes ask:
   `flux suspend hr`, scale to 0, and scale back after `flux resume` (resuming an
   unchanged release doesn't restore replicas).
3. Bump the digest-pinned tag, push, `flux reconcile ks apps --with-source`, check.
   Write the tag unquoted (`12.4@sha256:…`): a quoted scalar can't be followed by `@`.
4. A failed rung isn't a `zfs rollback`, since `fast/k8s` holds every app: use
   `scripts/rollback.sh` (below).

**Scripts for the apps that need more** (`scripts/`, each header says how to use it):
`nextcloud-rung.sh` (one major at a time, never skip), `home-assistant-rung.sh`
(about 6-month hops), `postgres-major.sh` (a Postgres major, with a row count
compared before and after), `jellyfin-state.sh` (counts to compare across rungs),
`arr-api.sh` and `arr-state.sh` (the *arrs' API). Forgejo: `forgejo manager
flush-queues` before, `forgejo doctor check --all` after. The *arrs go straight to
the current stable: their SQLite migrates on start.

**A plugin pinned by version and checksum** (Jellyfin's SSO plugin in
`apps/jellyfin/config/install-sso.py`, Home Assistant's `auth_oidc` in its
`release.yaml`): Renovate moves the version, CI stays red until the SHA-256 is
committed, and prints the one the new URL serves. Compare it with upstream's
release. Check compatibility first: Jellyfin's `targetAbi`, Nextcloud's
`user_oidc` `max-version`.

## Rollback

`scripts/rollback.sh <app> --revert <sha>`, without `--yes`, prints its plan and
changes nothing. With `--yes` it takes a safety snapshot, stops the app (its
HelmRelease, CronJobs and workloads, and hibernates its database), replaces each
volume and the database with the last snapshot before that commit (as the volume's
own uid, through a pod), checks the copy, reverts the commit, and starts the app.
It can stop on a failure and be run again.

- Nextcloud's files stay by default: an upgrade doesn't change them, and copying
  them back would delete what was uploaded since. `--with-files` is for damaged
  files, and needs sudo.
- A platform component (Traefik, cert-manager) holds nothing to copy back: revert
  the commit.
- **Rehearsed 2026-11-02**, twice, on a throwaway app with its own volume and
  database. **Never tried:** Nextcloud's `occ` steps and `--with-files`. Run the
  first real one with someone watching.

## Backups

Every night, on `tank`, a second copy on other disks than the SSDs and the NVMe:

| When | What | Where |
|---|---|---|
| 23:30 | `/persist`, from a read-only btrfs snapshot | `tank/backup/persist`, plain files |
| from 03:00 | a `pg_dump` of every database (`apps/pg-dump`) | `tank/backup/dumps/<cluster>/` |
| 03:30 | every `fast/*` dataset, by syncoid | `tank/backup/fast/`, read-only |

Retention and schedules are in the host's `.nix/hosts/def-jam/backups.nix`
(`.dotfiles`) and in `apps/pg-dump`. A failure reaches the phone.

**Restoring:**

- **One app's files:** scale it to 0, copy from
  `/srv/backup/fast/k8s/.zfs/snapshot/<snapshot>/<namespace>/<pvc>/` as root (or the
  dataset itself for last night's state). Databases: `tank/backup/fast/k8s-db`, same shape.
- **A database:** `pg_restore --single-transaction --exit-on-error -d <db> <dump>`
  into an empty cluster that already has the role (CNPG's `initdb` makes it).
- **The SSD pool died:** a new pool, `zfs send` the newest snapshot back from the
  replicas, `readonly=off` on them, and Flux re-attaches the same paths.
- **The NVMe died:** reinstall the host, the keys from the password manager, then the
  rest from `/srv/backup/persist` (the SSH host keys first: sops-nix needs them).
- Use GNU tar to restore archives: busybox and bsdtar mangle sparse files and
  non-ASCII names.

**The drill:** `scripts/restore-drill.sh` rebuilds Forgejo from the newest dump and
the replica alone, in a throwaway namespace with no internet, compares it with the
live one, and removes itself. **Last run 2026-11-20:** every table identical, every
repository passed `fsck` with refs identical to live, and cloned. Run it after any
change to the backups. It exercises Forgejo only; the other dumps have only been
read back as valid archives.

## Monitoring

- **Where alerts go:** Alertmanager pushes to ntfy (a private topic, a phone). Its
  `Watchdog` goes to healthchecks.io, which e-mails if it stops: a dead-man's
  switch for the whole path. The host pushes on its own too (ZFS events, failed
  backups and upgrades, a needed reboot), so a failing disk is reported with the
  cluster down.
- **This repo's rules:** `monitoring/rules/`, each with a line saying what to do.
  The chart's own rules cover the rest.
- **Blackbox probes** (`monitoring/blackbox-exporter.yaml`) catch an app that's Ready
  but broken: each route, through Traefik, with the real certificate, from inside the
  cluster. `-gate` targets check that a forward-auth route still redirects to the
  sign-in page. `scripts/ci/probes.sh` keeps routes and targets in step.
- **After a reboot**, a few things restart several times while the API server comes
  up (cert-manager, the CNPG operator, CoreDNS, metrics-server) and MetalLB's
  pool-usage rules fail for about a minute: normal.

## CI

`nix develop -c scripts/ci/all.sh`, on every pull request and push, with the same
tools everywhere (`flake.lock`). Each script's header says what it checks: `lint.sh`
(every formatter and linter), `build.sh` (every kustomization), `render.sh` (every
HelmRelease through its real chart and values), `validate.sh` (schemas, strict),
`secrets.sh`, `images.sh` (digests), `plugin-pins.sh`, `probes.sh`, `traefik.sh`.

The pre-push hook (`scripts/hooks/pre-push`) runs the same command on exactly the
commits being pushed, before Flux can see them. `main` has a ruleset requiring the
check; admins may push directly, Renovate can't.

`scripts/render-diff.sh [<base>]` shows what a change does to the manifests Flux
applies: nothing, for a refactor.
