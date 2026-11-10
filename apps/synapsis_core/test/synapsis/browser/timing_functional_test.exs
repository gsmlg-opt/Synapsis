defmodule Synapsis.Browser.TimingFunctionalTest do
  use ExUnit.Case, async: true
  @moduletag :functional

  alias Synapsis.Browser.Timing

  @config %{
    "default_profile" => "first",
    "profiles" => %{"first" => %{"timeout_ms" => 1000}, "second" => %{"timeout_ms" => 2000}}
  }

  test "all captured whole-source timing vectors match without changing their inputs" do
    fixture =
      Path.expand("../../../../..", __DIR__)
      |> Path.join("apps/synapsis_agent/test/fixtures/openclaw/488631c/browser-timing.json")
      |> File.read!()
      |> Jason.decode!()

    assert fixture["referenceCommit"] == "488631c18fae7cc541ba8fc8beff6cbb0438787b"
    assert length(fixture["vectors"]) == 15

    for vector <- fixture["vectors"] do
      raw = vector["rawRequest"]
      prepared = Timing.prepare_request(raw)
      assert prepared == vector["preparedRequest"], vector["name"]
      assert Timing.request_timeout_ms(prepared) == vector["requestTimeoutMs"], vector["name"]
      assert raw == vector["rawRequestAfter"], vector["name"]
      assert prepared == vector["preparedRequestAfter"], vector["name"]
    end
  end

  test "standalone model defaults are shallow and raw requests stay unchanged" do
    raw = %{"kind" => "click", "selector" => "button"}
    assert Timing.prepare_request(raw) == Map.put(raw, "timeoutMs", 60_000)
    assert raw == %{"kind" => "click", "selector" => "button"}
    batch = %{"kind" => "batch", "actions" => [raw]}
    assert Timing.prepare_request(batch) == batch
    assert Timing.request_timeout_ms(Timing.prepare_request(raw)) == 126_250
    assert Timing.request_timeout_ms(batch) == 65_000
  end

  test "serial conditions and children retain all phase budgets and transport slack once" do
    assert Timing.request_timeout_ms(%{
             "kind" => "batch",
             "actions" => List.duplicate(%{"kind" => "wait", "timeMs" => 30_000}, 3)
           }) == 95_000

    request = %{
      "kind" => "wait",
      "timeMs" => 30_000,
      "timeoutMs" => 120_000,
      "text" => "ready",
      "textGone" => "pending",
      "selector" => "#ready",
      "url" => "http://example.test",
      "loadState" => "load",
      "fn" => "() => true"
    }

    assert Timing.request_timeout_ms(%{
             "kind" => "batch",
             "actions" => List.duplicate(request, 100)
           }) == 75_005_000

    saturating = %{"kind" => "clickCoords", "timeoutMs" => 2_147_000_000, "x" => 1, "y" => 1}

    assert Timing.request_timeout_ms(%{
             "kind" => "batch",
             "actions" => List.duplicate(saturating, 100)
           }) == 2_147_000_000
  end

  test "outer overrides and profile aggregation select bounded native reserves once" do
    assert {:ok, %{outer_timeout_ms: 126_250, initialize_count: 1, native_timeout_ms: 149_250}} =
             Timing.plan(@config, %{
               "action" => "act",
               "args" => %{"request" => %{"kind" => "click", "selector" => "button"}}
             })

    assert {:ok, %{outer_timeout_ms: 150_000, initialize_count: 1, native_timeout_ms: 173_000}} =
             Timing.plan(@config, %{"action" => "act", "timeout_ms" => 150_000})

    assert {:ok, %{outer_timeout_ms: 3000, initialize_count: 2, native_timeout_ms: 36_000}} =
             Timing.plan(@config, %{"action" => "profiles"})

    assert {:ok, %{outer_timeout_ms: 150_000, initialize_count: 2, native_timeout_ms: 183_000}} =
             Timing.plan(@config, %{"action" => "profiles", "timeout_ms" => 150_000})

    assert {:ok, %{outer_timeout_ms: 1000, native_timeout_ms: 24_000}} =
             Timing.plan(@config, %{"action" => "status"})
  end

  test "existing successful host extensions retain their conservative phase allowance" do
    assert Timing.host_request_timeout_ms(%{
             "kind" => "batch",
             "actions" => [%{"kind" => "wait", "ref" => "e1", "timeoutMs" => 120_000}]
           }) == 125_000

    assert Timing.host_request_timeout_ms(%{
             "kind" => "batch",
             "actions" => [
               %{"kind" => "fill", "fields" => [%{"selector" => "input"}], "timeoutMs" => 60_000}
             ]
           }) == 65_250

    assert Timing.host_request_timeout_ms(%{
             "kind" => "batch",
             "actions" => [%{"kind" => "press", "selector" => "input", "delayMs" => 120_000}]
           }) == 133_250

    request = %{
      "kind" => "type",
      "selector" => "input",
      "slowly" => true,
      "text" => String.duplicate("a", 100),
      "delayMs" => 1000
    }

    assert Timing.host_request_timeout_ms(Timing.prepare_request(request)) == 217_750
  end
end
