# The tools CI runs, pinned by flake.lock, the same on a laptop and on any
# runner with Nix: `nix develop -c scripts/ci/all.sh`. Nothing in the cluster
# uses this (Flux applies only the paths in clusters/def-jam).
{
  description = "home-ops CI tools";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      devShells = forAll (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            actionlint
            curl
            gitleaks
            gnutar
            jq
            kube-linter
            kubeconform
            kubernetes-helm
            kustomize
            libxml2 # xmllint
            nginx
            php
            prometheus.cli # promtool
            ruff
            shellcheck
            shfmt
            yamllint
            yq-go
          ];
        };
      });
    };
}
