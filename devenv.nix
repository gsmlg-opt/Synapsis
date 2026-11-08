{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  env.GREET = "Synapsis";
  env.SYNAPSIS_FILESYSTEM_NODE = "${pkgs-stable.nodejs_24}/bin/node";
  # Use Vize's supported source selector on Linux with older host glibc.
  env.VIZE_EX_BUILD = lib.mkIf pkgs.stdenv.isLinux "1";

  packages = with pkgs-stable; [
    git
    deno
    figlet
    lolcat
    watchman
    beam28Packages.elixir-ls
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
    stdenv.cc
  ];

  languages.rust = lib.mkIf pkgs.stdenv.isLinux {
    enable = true;
    channel = "stable";
    version = "1.99.0";
    components = [ "rustc" "cargo" ];
    lsp.enable = false;
  };

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.package = pkgs-stable.nodejs_22;

  processes.synapsis = {
    exec = "mix synapsis.run";
  };

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  enterShell = ''
    hello
  '';

}
