#!/usr/bin/env bash
# This repo is public. Every Secret is SOPS-encrypted in a *.sops.yaml, every value
# in those really is encrypted, and nothing that looks like a credential is in
# the history. Never prints a value.
source "$(dirname "$0")/lib.sh"

# YAML files, parsed: a comment or a CRD's description mentioning Secret is fine.
while read -r f; do
  if [ -n "$(yq 'select(.kind == "Secret") | .kind' "$f")" ]; then
    fail "$f holds a kind: Secret outside a *.sops.yaml"
  fi
  if [ -n "$(yq 'select(has("secretGenerator")) | .kind' "$f" 2>/dev/null)" ]; then
    fail "$f has a secretGenerator: the Secret it makes would come from plaintext"
  fi
done < <(git ls-files '*.yaml' '*.yml' ':!*.sops.yaml' ':!.sops.yaml' "$generated")

# Each value under data and stringData, not just one somewhere in the file.
while read -r f; do
  if ! grep -q 'ENC\[' "$f"; then
    fail "$f holds no ENC[: not encrypted"
  fi
  plain=$(yq '(.data, .stringData) | select(. != null) | to_entries | .[] | select(.value | test("^ENC\[") | not) | .key' "$f")
  if [ -n "$plain" ]; then
    fail "$f has values that aren't encrypted, under keys: $(echo "$plain" | tr '\n' ' ')"
  fi
  if [ "$(yq 'select(.sops != null) | .sops.mac | length > 0' "$f" | sort -u)" != "true" ]; then
    fail "$f: a document without sops metadata"
  fi
done < <(git ls-files '*.sops.yaml' ':!.sops.yaml')

# The whole history: what was once pushed stays readable after a later commit
# removes it. --redact keeps a finding out of the public CI log.
if ! gitleaks git --redact --no-banner --config .gitleaks.toml .; then
  fail "gitleaks found something; rotate it, rewriting history doesn't unpublish it"
fi
exit $failed
