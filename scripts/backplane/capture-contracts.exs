# Run with MIX_ENV=dev devenv shell --no-tui -- mix run --no-start \
#   scripts/backplane/capture-contracts.exs --offline [--check]
Code.require_file("contracts.exs", __DIR__)
Synapsis.BackplaneContractCapture.main(System.argv())
