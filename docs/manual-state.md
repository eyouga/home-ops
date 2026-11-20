# Set outside git

Config lives in git wherever an app allows it. These settings can't: they're
held in an app's UI or database, so a rebuilt app needs them set again. Secrets
appear here only as variables, read from the app's `*.sops.yaml`.

## Sign-in providers

**Forgejo:**

```sh
forgejo admin auth add-oauth --name authelia --provider openidConnect \
  --key forgejo --secret "$OIDC_CLIENT_SECRET" \
  --auto-discover-url https://auth.eyouga.fr/.well-known/openid-configuration \
  --scopes openid --scopes profile --scopes email --scopes groups --skip-local-2fa
```

**Nextcloud** (`occ`, in the `nextcloud` container):

```sh
occ app:install user_oidc
occ user_oidc:provider authelia --clientid=nextcloud --clientsecret="$OIDC_CLIENT_SECRET" \
  --discoveryuri=https://auth.eyouga.fr/.well-known/openid-configuration \
  --scope="openid profile email" --unique-uid=0 --mapping-uid=preferred_username \
  --mapping-display-name=name --mapping-email=email --group-provisioning=0
occ config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends
```

Grafana, Jellyfin and Home Assistant take their sign-in from files in git.

## In an app's UI

- **Jellyfin:** NVENC and NVDEC hardware transcoding (Dashboard → Playback); the
  libraries, at `/media/{films,series,music}`; plugins from the catalogue.
- **Seerr:** its first-run wizard (the Jellyfin connection, Sonarr and Radarr),
  saved in its own `settings.json` on its volume.
- **The *arrs:** root folders under `/data/media`, Transmission as the download
  client (each with its own category), and Prowlarr's indexers, synced to the
  others. Quality profiles are in git (`apps/recyclarr`).
- **Home Assistant:** its integrations. Transmission's is
  `transmission.transmission.svc`, port 9091, no login.
