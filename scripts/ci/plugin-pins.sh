#!/usr/bin/env bash
# The two SSO plugins are installed by init containers, version and SHA-256 side by
# side. Renovate can move only the version, so its PR goes red here and prints
# the hash of what the new URL serves. Green means the pair agrees, not that the
# release is good: compare it with upstream's before merging (MIGRATION.md §10).
source "$(dirname "$0")/lib.sh"
check() { # <file> <url with $VERSION>
  local file=$1 url=$2 version sha actual
  version=$(sed -nE 's/^ *VERSION = "([^"]+)"$/\1/p' "$file")
  sha=$(sed -nE 's/^ *SHA256 = "([0-9a-f]{64})"$/\1/p' "$file")
  [ -n "$version" ] && [ -n "$sha" ] || { fail "$file: no VERSION or SHA256 found"; return; }
  url=${url//\$VERSION/$version}
  actual=$(curl -fsSL "$url" | sha256sum | cut -d' ' -f1)
  if [ "$actual" = "$sha" ]; then
    echo "ok   $file $version"
  else
    fail "$file: $url has SHA-256 $actual, the file says $sha"
  fi
}
check apps/jellyfin/config/install-sso.py 'https://github.com/MaxRink/jellyfin-plugin-sso/releases/download/v$VERSION/sso-auth_$VERSION.zip'
check apps/home-assistant/release.yaml 'https://github.com/christiaangoossens/hass-oidc-auth/releases/download/v$VERSION/hass-oidc-auth.zip'
exit $failed
