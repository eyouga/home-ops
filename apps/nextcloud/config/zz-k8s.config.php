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
);
