<?php
// What changed with the move to def-jam's cluster; the rest of the restored
// config.php holds as it was. Nextcloud reads every *.config.php in its
// config dir after config.php, and a key set here wins. Secrets come from
// the pod's environment (credentials.sops.yaml). Mounted read-only, so
// Nextcloud never edits this file; note that it saves the merged values
// whenever it rewrites config.php, as it did with the old passwords.
$CONFIG = array (
  'dbhost' => 'nextcloud-rw.databases.svc',
  'dbpassword' => getenv('NEXTCLOUD_DB_PASSWORD'),
  'redis' => array (
    'host' => 'redis.nextcloud.svc',
    'port' => 6379,
    'password' => getenv('REDIS_PASSWORD'),
  ),
  // Traefik's pods (k3s's cluster CIDR; the old cluster's were 172.16/16),
  // and notify_push, which reaches Nextcloud through the pod's nginx.
  'trusted_proxies' => array (
    0 => '10.42.0.0/16',
    1 => '127.0.0.1',
  ),
  // The old list minus OC\Preview\Imaginary: imaginary's image (tccr.io) is
  // gone, so images are previewed by PHP's imagick again.
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
  // Sign-in through Authelia (user_oidc; its provider is in the database,
  // MIGRATION.md). Client secret in the body, as Authelia's client expects; the
  // id token alone doesn't carry the name and address.
  'user_oidc' => array (
    'default_token_endpoint_auth_method' => 'client_secret_post',
    'enrich_login_id_token_with_userinfo' => true,
  ),
  // The issuer resolves to Traefik's LAN IP (hostAliases), which Nextcloud's HTTP
  // client refuses by default, with no per-host exception (the user's decision,
  // 2026-11-02; user_oidc PR 1598 would narrow this if released). What this guard
  // would stop is left to the NetworkPolicy: besides Traefik and its own
  // services, no private address is reachable from these pods.
  'allow_local_remote_servers' => true,
  // A new account starts empty: files:transfer-ownership --move needs that.
  'skeletondirectory' => '',
);
