# Architecture

## Layers

Flux applies five Kustomizations, each waiting for the one before
(`clusters/def-jam/`): the CRDs (`infra-crds`, `infra-crds-prometheus`), the
controllers (`infra-controllers`), their configuration (`infra-configs`), then
`monitoring` and `apps` side by side. `apps` doesn't wait for `monitoring`: a
broken dashboard must not hold back the apps.

Workloads depend only on the Kubernetes API and upstream projects: no
single-vendor charts, no NixOS services. If the host dies: reinstall it,
`flux bootstrap`, same repository.

## Platform

| Piece | Where | Role |
|---|---|---|
| MetalLB | `infrastructure/controllers/metallb`, pool in `infrastructure/configs/metallb/pool.yaml` | LoadBalancer IPs on the LAN, outside the router's DHCP range |
| Traefik | `infrastructure/controllers/traefik` | the Gateway API implementation; every web route goes through it |
| cert-manager | `infrastructure/controllers/cert-manager` | one wildcard certificate, by Cloudflare DNS-01 |
| CNPG | `infrastructure/controllers/cnpg` | one Postgres cluster per app, all in the `databases` namespace |
| NVIDIA device plugin | `infrastructure/controllers/nvidia` | the GPU, for Jellyfin's transcoding |
| blocky | `apps/blocky` | LAN DNS: ad blocking, and `eyouga.fr` answered with Traefik's IP |

Versions are in each `release.yaml`; git is the truth.

## Networking

- **Names:** every app is `<name>.eyouga.fr` (a few have their own: `auth.`, `git.`,
  `homeassistant.`, the apex for homepage). On the LAN, blocky answers them with
  Traefik's IP; public DNS doesn't change.
- **TLS:** Traefik holds the wildcard certificate; port 80 only redirects.
- **LAN only by default.** A route is public only through Traefik's `public`
  listener, which needs both the namespace label `eyouga.fr/public: "true"` and
  `sectionName: public` on the route. Never forward the router to the main
  HTTPS port: Traefik routes by name, so that would publish everything.
- **Pods reaching LAN names:** from a pod, `*.eyouga.fr` goes to public DNS, so
  an app that calls one gets a `hostAliases` entry with Traefik's IP and an
  egress rule to Traefik.
- **NetworkPolicy:** every app namespace denies everything by default, then
  allows only the real paths, with a rule on **both** ends of each.

## Storage

- **`fast`** (SSD mirror): the StorageClass of the same name puts every PVC at
  `/var/lib/k8s-volumes/<namespace>/<pvc>`, a plain directory. A restore is a copy
  into it, and a rebuilt cluster re-attaches to the same directory. Volumes are
  retained when their PVC goes. Databases have their own dataset.
- **`tank`** (RAIDZ2): bulk data, as static PVs on host paths. `tank/data` holds the
  torrents and the media library in **one** dataset, mounted as one `/data` in
  Transmission and the *arrs, so imports are hardlinks, not copies.
- **The *arrs own the library.** Jellyfin and Nextcloud mount it read-only, and no
  app rewrites a file there: a tag written on a hardlink would change the torrent.

The datasets themselves are defined on the host (`.dotfiles`,
`.nix/hosts/def-jam/disko-config.nix`).

## Every app has the same shape

Copy `apps/blocky` (no storage) or `apps/sonarr` (with storage). Each app has:

- its own namespace with Pod Security `restricted` (enforce and warn);
- a default-deny `networkpolicy.yaml`, then only its real paths;
- a HelmRelease of bjw-s' app-template, from the one source in
  `apps/app-template.yaml`, with an image pinned by digest, requests and a memory
  limit on every container (init containers too), a read-only root, all
  capabilities dropped, and a Helm timeout longer than its startup probe allows;
- `route.yaml` only if it has a UI, and a forward-auth or OIDC sign-in (see
  [sso.md](sso.md));
- config an app only reads in `config/`, as a hashed ConfigMap named
  `<app>-files` and mounted as the volume `files` (`configMapGenerator` +
  `kustomizeconfig.yaml`), so an edit rolls the pod; files it rewrites are
  copied in by an init container at each start (Transmission);
- secrets only as `*.sops.yaml`.

A deviation from this says why in a comment next to it.

## Secrets

SOPS with age. Every Secret is a `*.sops.yaml` with only its values encrypted;
Flux decrypts them with a key that exists only on the Mac and in the cluster. CI
checks that no plaintext Secret or unencrypted value is committed, and runs
gitleaks over the whole history.
