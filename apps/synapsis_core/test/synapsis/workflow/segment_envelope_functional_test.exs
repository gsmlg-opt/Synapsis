defmodule Synapsis.Workflow.SegmentEnvelopeFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.Workflow.{Schema, Segment}
  alias Synapsis.Workflow.Schema.PortSession

  @fixture Path.expand("../../fixtures/workflow_segment_cases.json", __DIR__)
  @external_resource @fixture
  @cases @fixture |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")
  @moduletag timeout: 120_000

  # Independent literal public JSON: JavaScript insertion order, two spaces,
  # no trailing newline. In particular the wrapper appends type after the token.
  @completed "{\n  \"ok\": true,\n  \"status\": \"ok\",\n  \"output\": [],\n  \"requiresApproval\": null\n}"
  @resumed "{\n  \"ok\": true,\n  \"status\": \"ok\",\n  \"output\": [\n    {\n      \"tag\": \"ready\"\n    }\n  ],\n  \"requiresApproval\": null\n}"
  @checkpoint "{\n  \"ok\": true,\n  \"status\": \"needs_input\",\n  \"output\": [],\n  \"requiresApproval\": null,\n  \"requiresInput\": {\n    \"prompt\": \"Choose tag\",\n    \"responseSchema\": {\n      \"type\": \"object\",\n      \"properties\": {\n        \"tag\": {\n          \"type\": \"string\"\n        }\n      },\n      \"required\": [\n        \"tag\"\n      ],\n      \"additionalProperties\": false\n    },\n    \"resumeToken\": \"literal-host-locator\",\n    \"type\": \"input_request\"\n  }\n}"

  test "actual pure boundaries render exact ordered public envelopes through the packaged helper" do
    for item <- @cases do
      assert {:ok, initial} = Segment.new(item["pipeline"])

      with_helper(fn helper ->
        {kind, boundary, requests} = drive(initial, helper)
        assert requests == item["before_requests"]
        assert boundary["journal"] == initial["journal"]
        assert boundary == boundary |> Jason.encode!() |> Jason.decode!()

        expected = if kind == :complete, do: @completed, else: @checkpoint
        assert_render(boundary, "literal-host-locator", expected)

        if kind == :checkpoint do
          assert boundary["machine"]["checkpoint"]["mode"] == item["mode"]
          assert {:ok, resumed} = Segment.resume(boundary, item["response_json"])
          assert Enum.map(resumed["machine"]["program"], & &1["name"]) == item["resumed_program"]
          assert {:complete, completed, requests} = drive(resumed, helper)
          assert requests == item["claim_requests"] ++ item["after_requests"]
          assert_render(completed, "unused", @resumed)
        end
      end)
    end
  end

  test "published pretty text counts actual UTF-8 bytes for an ordinary Unicode response" do
    item = Enum.find(@cases, &(&1["name"] == "same_stage"))
    assert {:ok, initial} = Segment.new(item["pipeline"])

    with_helper(fn helper ->
      assert {:checkpoint, checkpoint, _requests} = drive(initial, helper)
      assert {:ok, resumed} = Segment.resume(checkpoint, ~s({"tag":"雪😀"}))
      assert {:complete, completed, _requests} = drive(resumed, helper)
      text = String.replace(@resumed, "ready", "雪😀")
      assert_render(completed, "unused", text)
      assert byte_size(text) == byte_size(@resumed) + 2
      assert String.length(text) == String.length(@resumed) - 3
    end)
  end

  defp assert_render(snapshot, token, expected) do
    assert {:ok, %{text: text, envelope: envelope}} = Segment.render_envelope(snapshot, token)
    assert text === expected
    assert byte_size(text) === byte_size(expected)
    assert envelope === Jason.decode!(expected)
    assert {:ok, ^envelope} = Segment.envelope(snapshot, token)
  end

  defp drive(snapshot, helper, requests \\ []) do
    case Segment.advance(snapshot) do
      {:continue, next} ->
        drive(next, helper, requests)

      {:request, request, pending} ->
        assert {:continue, machine} = Schema.advance_pending(helper, pending["machine"], 15_000)

        drive(
          Map.put(pending, "machine", machine),
          helper,
          requests ++ [[request["kind"], request["boundary"]]]
        )

      {kind, _value, next} when kind in [:checkpoint, :complete] ->
        {kind, next, requests}

      other ->
        flunk("unexpected ordinary transition: #{inspect(other)}")
    end
  end

  defp with_helper(fun) do
    helper =
      start_supervised!(
        {PortSession,
         owner_pid: self(),
         node_executable: System.fetch_env!("SYNAPSIS_FILESYSTEM_NODE"),
         helper_path:
           Path.join(:code.priv_dir(:synapsis_core), "workflow_schema/schema-stdio.mjs")},
        id: make_ref()
      )

    try do
      result = fun.(helper)

      assert {:ok, %{cleanup_confirmed: true, os_pid: pid, exit_status: status}} =
               PortSession.close(helper)

      if pid do
        assert status == 0
        refute File.exists?("/proc/#{pid}")
      end

      result
    after
      if Process.alive?(helper), do: PortSession.close(helper)
    end
  end
end
