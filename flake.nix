{
  description = "Synapsis — AI coding agent in Elixir/Phoenix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkgs-unstable = import nixpkgs-unstable { inherit system; };
        beamPackages = pkgs.beam27Packages;
        elixir = beamPackages.elixir;
        erlang = beamPackages.erlang;
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            elixir
            erlang
            pkgs.postgresql_16
            pkgs.bun
            pkgs.tailwindcss_4
            pkgs.git
            pkgs.ripgrep
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.inotify-tools
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.CoreFoundation
            pkgs.darwin.apple_sdk.frameworks.CoreServices
          ];

          shellHook = ''
            export MIX_BUN_PATH="${pkgs.lib.getExe pkgs.bun}"
            export MIX_TAILWIND_PATH="${pkgs.lib.getExe pkgs.tailwindcss_4}"
            export ERL_AFLAGS="-kernel shell_history enabled"
            echo "Synapsis dev environment loaded"
            echo "  Elixir: $(elixir --version | tail -1)"
            echo "  PostgreSQL: $(postgres --version)"
            echo "  Bun: $(bun --version)"
          '';
        };
      }
    );
}
