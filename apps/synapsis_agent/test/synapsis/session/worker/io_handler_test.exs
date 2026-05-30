defmodule Synapsis.Session.Worker.IOHandlerTest do
  # The poll-retry resume race (`:not_waiting`) is eliminated in the Engine
  # collapse (ADR-006 A1) — the Worker now steps the engine inline, so there
  # is no separate Runner process to race against. Tests for IOHandler I/O
  # handling live in the integration-level session worker tests.
  use ExUnit.Case, async: true
end
