# home-ops

Everything that runs in the k3s cluster on **def-jam**, a home server, applied
by [Flux](https://fluxcd.io) from this repository's `main` branch. The host
itself (NixOS, disks, ZFS, k3s) lives in a separate repository,
[`.dotfiles`](https://github.com/eyouga/.dotfiles), under `.nix/hosts/def-jam/`.
NixOS knows about k3s, never about the apps.

## Layout

| Path | What | Applied by |
|---|---|---|
| `clusters/def-jam/` | Flux's own manifests and the Kustomizations below | `flux bootstrap` |
| `infrastructure/controllers/` | MetalLB, Traefik, cert-manager, CNPG, the NVIDIA device plugin | `infra-controllers` |
| `infrastructure/configs/` | their configuration: IP pool, Gateway, certificate issuer, StorageClass | `infra-configs` |
| `monitoring/` | kube-prometheus-stack, exporters, blackbox probes, alert rules, dashboards | `monitoring` |
| `apps/` | one directory per app, each in its own namespace | `apps` |
| `scripts/` | upgrade, rollback and restore helpers; `scripts/ci/` holds the checks | by hand |

The CRDs come first (`infra-crds`, `infra-crds-prometheus` in
`clusters/def-jam/infrastructure.yaml`), so every later layer can use them.

## Docs

- [Architecture](docs/architecture.md): the layers, the platform, how every app is shaped.
- [Operations](docs/operations.md): upgrades, rollback, backups and restores, monitoring, CI.
- [Sign-in](docs/sso.md): how SSO works, and how an app joins it.
- [Set outside git](docs/manual-state.md): the few settings that live in an app's UI or database.
- [Contributing](CONTRIBUTING.md): the rules this repository keeps.

## Checks

```sh
nix develop -c scripts/ci/all.sh
```

The same command CI runs on every push and pull request, and the pre-push hook
runs before anything reaches `main` (switch it on once per clone:
`git config core.hooksPath scripts/hooks`). No secrets and no cluster needed.
