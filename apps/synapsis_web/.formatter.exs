[
  import_deps: [:phoenix, :phoenix_html, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter, DuskmoonBundler.Formatter],
  inputs: [
    "*.{ex,exs}",
    "{config,lib,test}/**/*.{ex,exs,heex}",
    "assets/**/*.{js,ts,jsx,tsx}"
  ]
]
