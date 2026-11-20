<?php
// Overrides on top of config.php on the PVC. Nextcloud reads every *.config.php
// in its config dir after config.php, and a key set here wins. Secrets come from
// the pod's environment (credentials.sops.yaml). Mounted read-only, so Nextcloud
// never edits this file; but it saves the merged values whenever it rewrites
// config.php, so a secret set here can end up on the PVC.
$CONFIG = array (
  'dbhost' => 'nextcloud-rw.databases.svc',
  'dbpassword' => getenv('NEXTCLOUD_DB_PASSWORD'),
  'redis' => array (
    'host' => 'redis.nextcloud.svc',
    'port' => 6379,
    'password' => getenv('REDIS_PASSWORD'),
  ),
  // Traefik's pods (k3s's cluster CIDR),
  // and notify_push, which reaches Nextcloud through the pod's nginx.
  'trusted_proxies' => array (
    0 => '10.42.0.0/16',
    1 => '127.0.0.1',
  ),
  // No OC\Preview\Imaginary: nothing runs Imaginary, so PHP's imagick makes
  // the previews.
  'enabledPreviewProviders' => array (
    0 => 'OC\\Preview\\BMP',
    1 => 'OC\\Preview\\GIF',
    2 => 'OC\\Preview\\JPEG',
    3 => 'OC\\Preview\\Krita',
    4 => 'OC\\Preview\\MarkDown',
    5 => 'OC\\Preview\\MP3',
    6 => 'OC\\Preview\\OpenDocument',
    7 => 'OC\\Preview\\PNG',
    8 => 'OC\\Preview\\TXT',
    9 => 'OC\\Preview\\XBitmap',
  ),
  // Heavy daily background jobs run in the 4 hours from 01:00 UTC
  // (02:00–06:00 in Paris), not whenever cron happens to pick them.
  'maintenance_window_start' => 1,
  // Sign-in through Authelia (user_oidc; its provider is in the database:
  // `occ user_oidc:provider`). Client secret in the body, as Authelia's client expects; the
  // id token alone doesn't carry the name and address.
  'user_oidc' => array (
    'default_token_endpoint_auth_method' => 'client_secret_post',
    'enrich_login_id_token_with_userinfo' => true,
  ),
  // TEMPORARY: until user_oidc can trust a single host (its PR 1598). The issuer
  // resolves to Traefik's LAN IP (hostAliases), which Nextcloud's HTTP client
  // refuses by default, with no per-host exception. What this guard would stop
  // is left to the NetworkPolicy: besides Traefik and its own services, no
  // private address is reachable from these pods.
  'allow_local_remote_servers' => true,
  // A new account starts empty, without the sample files.
  'skeletondirectory' => '',
);
