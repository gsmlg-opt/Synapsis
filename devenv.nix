{ pkgs, lib, config, inputs, ... }:

let
  pkgs-stable = import inputs.nixpkgs-stable { system = pkgs.stdenv.system; };
  pkgs-unstable = import inputs.nixpkgs-unstable { system = pkgs.stdenv.system; };
in
{
  env.GREET = "Synapsis";
  env.MIX_BUN_PATH = lib.getExe pkgs-stable.bun;
  env.MIX_TAILWIND_PATH = lib.getExe pkgs-stable.tailwindcss_4;

  packages = with pkgs-stable; [
    git
    figlet
    lolcat
    watchman
    bun
    tailwindcss_4
  ] ++ lib.optionals stdenv.isLinux [
    inotify-tools
  ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam27Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.pnpm.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  # PostgreSQL database service
  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_16;
    listen_addresses = "";  # Empty string = Unix socket only
    initialDatabases = [
      { name = "synapsis"; }
    ];
    initialScript = ''
      CREATE USER synapsis WITH PASSWORD 'synapsis' CREATEDB;
      GRANT ALL PRIVILEGES ON DATABASE synapsis TO synapsis;
      ALTER DATABASE synapsis OWNER TO synapsis;
    '';
  };

  # Set DATABASE_URL for Ecto to use Unix socket
  env.DATABASE_URL = "postgres://synapsis:synapsis@localhost/synapsis?socket=${config.env.DEVENV_STATE}/postgres";
  env.PGHOST = "${config.env.DEVENV_STATE}/postgres";
  env.PGUSER = "synapsis";
  env.PGDATABASE = "synapsis";

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  scripts.db-setup.exec = ''
    echo "Setting up database..."
    mix ecto.create
    mix ecto.migrate
    echo "Database setup complete!"
  '';

  enterShell = ''
    hello
    echo "PostgreSQL socket: $PGHOST"
  '';

}
