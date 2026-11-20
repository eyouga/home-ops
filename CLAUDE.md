# home-ops

The def-jam cluster: everything in it, applied by Flux from `main`. How it works is
in README.md and docs/.

@CONTRIBUTING.md

## This repo

- A lasting change goes through git: Flux applies `main`. To apply it now:
  `flux reconcile ks <layer> --with-source`.
- The pre-push hook runs `nix develop -c scripts/ci/all.sh` on what's pushed. Switch
  it on once per clone: `git config core.hooksPath scripts/hooks`.
- A refactor proves itself with `scripts/render-diff.sh`: no output.
- The host is in `~/.dotfiles/.nix`. A session here doesn't load that repo's
  CLAUDE.md: read it before changing anything there.
- The open list is local, on the owner's Mac:
  `~/.dotfiles/.nix/hosts/def-jam/MIGRATION.md`. Read its §1 and §2 before def-jam work.
- TEMPORARY: until the migration's last phase (Phase 11) is done: no Learn-by-Doing
  exercises or `TODO(human)` here, whatever the output style asks. Decide,
  implement, verify, explain briefly.

## Working rules

- **Secrets are the owner's.** Claude's permission check refuses Claude writing
  Kubernetes Secrets and keys. Hand over one line that generates the value and pipes
  it in: `... | sops encrypt --filename-override <path>.sops.yaml > <path>.sops.yaml`,
  so no plaintext touches the disk. To change one, the owner runs
  `SOPS_EDITOR=nvim sops edit <file>`. Verify with an `ENC[` grep. Anything that needs
  the plaintext runs in a script that prints only booleans.
- **Credentials given to something else aren't Claude's,** even read-only. DNS is
  the owner's, in Cloudflare's dashboard; check it from outside with `dig`.
- **Redact when reading.** Whatever is printed stays in the transcript, and a leak
  means rotating. On a file that may hold secrets, print key names only, or parse it
  and drop the values. Don't grep and mask afterwards. This covers any key containing
  pass, secret, token or key, and the password in a URL. Read archives in memory;
  delete scratch copies.
- **Pull requests are the owner's click.** `gh pr merge` on Claude's own PR is
  refused. Don't route around it: no pushing that branch to the default branch, no
  `--auto`, no `--admin`. Renovate's open PRs are the owner's to merge or close.
- **Direct pushes to the default branch are normal,** through the pre-push hook, never
  with `--no-verify`. GitHub's `Bypassed rule violations` is expected.
- **The checkouts are shared.** Other sessions work in `~/Code/home-ops` and
  `~/.dotfiles` at the same time. Never switch branches, stash, reset or rebase there.
  Branch work goes in a worktree; a modified copy in a `mktemp -d` clone.
- **Rehearse against real behaviour.** Reading isn't proof. A rollback, restore,
  upgrade path or alert runs for real on something throwaway, with a deliberate
  failure, and the date goes next to its procedure. Say what wasn't rehearsed.
- **Measure, don't assume.** State what wasn't checked. No silent caps: a capped
  search once made an old release look current. Empty output with stderr hidden
  proves nothing.
- **Both repos are public** and history isn't rewritten. Never in a commit, comment,
  PR or issue: the house's public IP, people's names or accounts, weaknesses not
  fixed yet. Those stay in the local MIGRATION.md, which is gitignored: don't commit
  it or offer to.
- **Irreversible removals are the owner's,** and so is sudo. List them as commands
  with their conditions.
- **Both machines run zsh.** `echo ===` fails, unquoted variables don't split, a glob
  with no match is an error, and `?` in an unquoted URL is a glob. Use `print -r --`,
  quote, or `bash -c`.
- **def-jam** is `ssh 192.168.1.80`: it has kubectl, but no jq, python3, flux or
  sops; `nix shell nixpkgs#<tool> -c ...` gets the rest. `eyouga` may
  `zfs snapshot` `fast/k8s` and `fast/k8s-db` without sudo.
