# Contributing

The rules this repository keeps, for anyone changing it, people and tools alike.
`.dotfiles` keeps the same ones.

## Docs and comments

1. **The repository explains itself.** With only this repository you can understand
   the cluster, run it and restore it: the README and `docs/`. Private details
   (home address and IP, people's account names, weaknesses not yet fixed) stay out.
2. **A comment says why it is this way now, not how it got here.** History belongs
   in git. The test: if this comment vanished, could someone make a wrong change?
   An edit to a file under `config/` restarts its pod: commit it on its own, at a
   quiet time.
3. **Each fact has one owner.** Docs point to the file instead of copying its value.
   Code repeats a fact only when it must, and then a check or a Renovate group keeps
   the copies in agreement.
4. **Anything temporary says when it goes:** `TEMPORARY: until <condition>`, next to
   it. If a machine can see the condition, an alert says when it's met. CI rejects a
   marker without `until`.

## Code

5. **If a tool can check a rule, CI checks it.** Every language has a formatter and a
   linter (`scripts/ci/lint.sh`); settings live in config files. A finding is fixed,
   or silenced on its line with the reason.
6. **Every app has the same shape** ([architecture](docs/architecture.md)), and CI
   checks it. A deviation says why in a comment next to it.
7. **Plain beats clever.** A file you can read top to bottom beats an abstraction.
   Share only what must change together, in the plainest way: a YAML anchor in one
   file, then a shared file. No templating layer.
8. **Small units, one job each.** A script over about 150 lines says why in its
   header. Split by job, never by length alone.
9. **Dead code is deleted, not commented out.** No TODO or FIXME: do it, mark it
   `TEMPORARY: until …`, or put it on the open list.
10. **Every dependency is pinned and something updates it.** Images by digest, charts
    by version; data feeds (blocklists, TRaSH guides) and apps' own plugin stores are
    the written exceptions. A pull request open over 30 days says why on it.

## Changes

11. **One change per commit.** Subject `scope: what changed`: lower-case scope (the
    app, or `ci`, `monitoring`, `renovate`…), under 72 characters, one thought. The
    why goes in the body. Experiments go on a branch; a rehearsal Flux must see goes
    on `main` as `rehearsal: …`, reverted in the same sitting. `main`'s history is
    never rewritten.
12. **Cleanup doesn't change behaviour, and proves it:** `scripts/render-diff.sh`
    shows no difference (for a file under `config/`, only its ConfigMap's new name).
    Anything that changes behaviour goes in its own commit.
13. **Direct pushes to `main` go through the pre-push hook** (`git config
    core.hooksPath scripts/hooks`). Changes that could take an app down or lock
    people out go through a pull request: storage or database layout, Flux, Traefik
    and the Gateway, sign-in. Never push with `--no-verify`.

## The cluster

14. **Workloads depend only on the Kubernetes API and upstream projects:** no
    single-vendor charts, no NixOS services for apps.
15. **Config in git over config in a UI.** What only a UI can hold is listed in
    [manual-state.md](docs/manual-state.md).
16. **Secrets only as `*.sops.yaml`,** encrypted before they touch the disk:
    `… | sops encrypt --filename-override apps/<app>/<file>.sops.yaml > apps/<app>/<file>.sops.yaml`.
    Database passwords: `openssl rand -hex 24` (no URL escaping needed).
17. **Stable releases only.** home-operations' images build the develop branch: pin
    only builds that are an upstream stable release.
18. **The *arrs own the media library.** Everything else mounts it read-only.
19. **Nothing the cluster needs to start may live on Forgejo.** Flux and the host's
    upgrades pull from GitHub; Forgejo only mirrors.
20. **Every route asks for sign-in** ([sso.md](docs/sso.md)), and is public only
    through the `public` listener.
21. **Prefer an app's own API or CLI to editing its database by hand.**

## Server and recovery

22. **Git explains everything on the server except data.** What can't be in git is
    listed with the command that sets it.
23. **Nothing deletes data on its own** apart from the retention written in git. Any
    other irreversible removal is a command for the owner, run once its condition
    is met, after whatever refers to the thing is gone.
24. **Every failure reaches the phone, with what to do; every recovery is rehearsed,
    with the date next to its procedure** ([operations](docs/operations.md)). An
    alert that fires without meaning anything is fixed or removed.
25. **Hygiene is reviewed every month,** for what CI can't see: markers whose
    condition came true, stale pull requests, hand-made changes on the server,
    rehearsals older than six months.
