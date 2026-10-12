{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
in
{
  env.GREET = "Synapsis";

  packages = with pkgs-stable; [
    git
    figlet
    lolcat
    watchman
    beam28Packages.elixir-ls
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

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
