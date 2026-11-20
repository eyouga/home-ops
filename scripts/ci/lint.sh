#!/usr/bin/env bash
# Every formatter and linter this repo has, on every tracked file of its kind.
# Settings live in .shellcheckrc, .editorconfig (shfmt) and .yamllint.yaml. A
# finding is fixed, or silenced on its line with the reason.
# Not here: renovate-config-validator (a 1.7 GiB package); Renovate reports a broken
# config itself, in an issue.
source "$(dirname "$0")/lib.sh"
mine=":!scripts/ci/lint.sh"

files() { git ls-files "$@" "$generated"; }
mapfile -t sh < <(files '*.sh' 'scripts/hooks/*')
shellcheck "${sh[@]}" || fail shellcheck
shfmt -d "${sh[@]}" || fail "shfmt: run shfmt -w on these"
yamllint -s . || fail yamllint
actionlint || fail actionlint

# promtool reads the rule groups, i.e. the PrometheusRule's spec.
rules=$(mktemp)
trap 'rm -f "$rules"' EXIT
while read -r f; do
  yq '.spec' "$f" >"$rules"
  promtool check rules "$rules" >/dev/null || fail "promtool: $f"
done < <(files 'monitoring/rules/*.yaml')

while read -r f; do php -l "$f" >/dev/null || fail "php -l $f"; done < <(files '*.php')
while read -r f; do xmllint --noout "$f" || fail "xmllint $f"; done < <(files '*.xml')
while read -r f; do jq empty "$f" || fail "jq: $f"; done < <(files '*.json')
mapfile -t py < <(files '*.py')
ruff check "${py[@]}" || fail "ruff check"
ruff format --check "${py[@]}" || fail "ruff format: run ruff format on these"

# Nextcloud's nginx.conf, with the image's paths moved under a temporary prefix.
# Its warning about "js" is upstream's mjs mapping, on purpose.
ng=$(mktemp -d)
trap 'rm -f "$rules"; rm -rf "$ng"' EXIT
conf=$(dirname "$(readlink -f "$(command -v nginx)")")/../conf
mkdir -p "$ng/log" "$ng/tmp/nginx"
cp "$conf/mime.types" "$conf/fastcgi_params" "$ng/"
# /tmp first: the prefix itself may be under /tmp.
sed -e "s#/tmp/#$ng/tmp/#g" -e "s#/etc/nginx/#$ng/#g" -e "s#/var/log/nginx/#$ng/log/#g" \
  apps/nextcloud/config/nginx.conf >"$ng/nginx.conf"
if ! out=$(nginx -t -p "$ng" -e "$ng/log/error.log" -c "$ng/nginx.conf" 2>&1); then
  echo "$out" >&2
  fail "nginx -t apps/nextcloud/config/nginx.conf"
fi

# Open work is done, marked TEMPORARY with its end, or on the open list.
if git grep -n -w -E 'TODO|FIXME' -- . "$generated" "$mine" ':!monitoring/dashboards/*.json'; then
  fail "TODO or FIXME: do it, mark it 'TEMPORARY: until <condition>', or put it on the open list"
fi
if git grep -n 'TEMPORARY' -- . "$generated" "$mine" | grep -v 'TEMPORARY: until '; then
  fail "a TEMPORARY marker without 'TEMPORARY: until <condition>'"
fi
exit $failed
