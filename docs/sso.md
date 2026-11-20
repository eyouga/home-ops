# Sign-in

Every route asks for **Authelia** (`apps/authelia`, at `auth.eyouga.fr`), either by
OIDC or through a forward-auth `Middleware` in the app's namespace. There is no
second way in around it: an app's own password login is turned off or given a
random password. Machine credentials stay (app passwords, access tokens, API
keys), each revocable on its own.

## How it works

- `config/configuration.yml` is Authelia's configuration; `users.sops.yaml` holds
  the accounts and their groups, and `access_control` decides which group may open
  which app. `secrets.sops.yaml` holds the rest. Authelia has its own Postgres.
- **Sessions live in memory: any change to Authelia's configuration signs everyone
  out.** Its template filter also reads comments, so no template syntax in them.
- Each OIDC client's secret exists twice: a PBKDF2 digest in Authelia's
  configuration, the plaintext in the app's `oidc.sops.yaml`.

| App | Sign-in |
|---|---|
| Grafana, Forgejo | OIDC |
| Nextcloud | OIDC (`user_oidc`) |
| Jellyfin | OIDC through the SSO plugin (an init container installs it); TV and phone apps through Quick Connect |
| Home Assistant | OIDC through `auth_oidc` (an init container installs it) |
| Seerr | forward-auth, then Jellyfin's Quick Connect |
| the *arrs, Transmission, homepage, Prometheus, Alertmanager | forward-auth |

Each forward-auth route keeps one harmless open path (`/ping`, a favicon,
`/-/healthy`), so homepage's status dots and the blackbox probes still test the
route, the certificate and the app. The *arrs trust the header (`Auth Method:
External`) and set their allowed hosts by environment.

## Adding an app

- **OIDC:** a client in Authelia's `configuration.yml`, its digest in Authelia's
  `secrets.sops.yaml`, the plaintext in the app's `oidc.sops.yaml`, a `hostAliases`
  entry for `auth.eyouga.fr`, and egress to Traefik in the app's NetworkPolicy.
- **Forward-auth:** copy the `Middleware` and the two rules from
  `apps/sonarr/route.yaml`, and add the app to `access_control`.
- **A route in a new namespace:** Traefik ignores it until the namespace is in both
  `namespaces` lists in Traefik's `release.yaml` and in Traefik's NetworkPolicy
  egress, with a RoleBinding to `traefik-read-secrets` next to the route (copy it from
  `apps/sonarr/route.yaml`). `scripts/ci/traefik.sh` fails until all four agree.

## Accounts

`sops edit apps/authelia/users.sops.yaml`. A new password is a new argon2id digest:

```sh
nix shell nixpkgs#libargon2 -c sh -c \
  'printf %s "$PW" | argon2 "$(openssl rand -hex 16)" -id -t 3 -k 65536 -p 4 -l 32 -e'
```

The portal can't change passwords: the file is read-only to Authelia.

## Worth knowing

- **Jellyfin's SSO plugin:** rename an account **before** its first SSO login, or the
  plugin creates a new one. Accounts it creates carry its own provider,
  `SSOController`, which Jellyfin treats as invalid: every password is refused, and a
  password change silently does nothing. `POST /sso/Unregister/<user>` with the
  default provider's name undoes it. SSO-only takes effect only when saved through
  the plugin's page or API, or when a link is created. The account links live in
  `SSO-Auth.xml`, and the init container keeps them across restarts.
- **Nextcloud's passwords:** `OC_PASS=… occ user:resetpassword --password-from-env`
  kills the old password at once; app passwords survive it. Re-test before relying on
  a change there.
- **Nextcloud and Authelia's LAN address:** see `allow_local_remote_servers` in
  `apps/nextcloud/config/zz-k8s.config.php`.
- **Authelia answers 401** instead of redirecting without `Accept: text/html`, and
  200 on any path: a probe of it checks the page's content.

## Public apps

A route is public only through Traefik's `public` listener: the namespace label
`eyouga.fr/public: "true"` **and** `sectionName: public` on the route. Everything
else is LAN only.
