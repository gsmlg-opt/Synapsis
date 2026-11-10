defmodule Synapsis.Agent.Tools.ReadableFetchNativeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore}
  alias Backplane.AgentRuntime.Codex.{Backend, Services}
  alias Synapsis.Agent.TestSupport.BackplaneRuntimeProof, as: Proof

  @name "web::fetch"
  @readable_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["url"],
    "properties" => %{
      "url" => %{"type" => "string", "format" => "uri"},
      "instructions" => %{"type" => "string"},
      "extract_mode" => %{"type" => "string", "enum" => ["markdown", "text"]},
      "max_chars" => %{"type" => "integer", "minimum" => 1}
    }
  }

  # This is an explicit host-adapter contract fixture, not an HTTP transport or
  # an extraction implementation. Its document is supplied by each test.
  defmodule HostReadableAdapter do
    @behaviour Backplane.AgentRuntime.Codex.Web.ReadableFetch

    @impl true
    def fetch(arguments, opts) do
      observation =
        case Keyword.get(opts, :runtime_context) do
          nil ->
            nil

          runtime ->
            {:ok, committed} =
              EphemeralStore.load(Keyword.fetch!(opts, :proof_store), runtime.identity.run_id)

            first = runtime.effect_deadline.()
            second = runtime.effect_deadline.()
            [supervisor | _] = Process.get(:"$ancestors")

            %{
              runtime: runtime,
              committed: committed,
              deadlines: {first, second},
              adapter_pid: self(),
              supervisor: supervisor,
              effect_owner_alive: Process.alive?(runtime.effect_owner_pid)
            }
        end

      send(
        Keyword.fetch!(opts, :proof_pid),
        {:readable_host_called, arguments, opts, observation}
      )

      {:ok, Keyword.fetch!(opts, :proof_document)}
    end
  end

  test "default service profile retains revision one and fetches the raw HTTP document" do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    owner = self()
    body = "<html><body><nav>Menu</nav><main>Raw café article.</main></body></html>"

    Gaoxy.Test.stub(fixture, "GET", "/raw", fn conn ->
      send(owner, :raw_http_requested)
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)

    url = Gaoxy.Test.url(fixture, "/raw")
    context = %{web_allowed_hosts: [URI.parse(url).host], web_transport: Synapsis.Web.Transport}
    bundle = profile!(context, "readable-default", 1)
    descriptor = bundle.registry.tools[@name]

    assert descriptor.backend == Backend
    assert descriptor.backend_context == %{family: :service, context: context}
    assert descriptor.tool_revision == 1

    assert descriptor.schema ==
             Map.update!(@readable_schema, "properties", &Map.take(&1, ["url", "instructions"]))

    assert {:ok, result} = Services.call(context, @name, %{"url" => url})
    assert_receive :raw_http_requested, 1_000
    assert result.status == 200
    assert result.url == url
    assert result.body == body
    assert result.content_type == "text/html; charset=utf-8"
    assert {"content-type", result.content_type} in result.headers
  end

  test "explicit host adapter selects the original revision two schema and preserves text metadata" do
    url = "https://readable.example/article"

    arguments = %{
      "url" => url,
      "instructions" => "Read the article",
      "extract_mode" => "text",
      "max_chars" => 4096
    }

    document = document(url, "Café article in plain text.")
    context = readable_context(url, document)
    bundle = profile!(context, "readable-standalone", 2)
    descriptor = bundle.registry.tools[@name]

    assert descriptor.backend == Backend
    assert descriptor.backend_context == %{family: :service, context: context}
    assert descriptor.tool_revision == 2
    assert descriptor.schema == @readable_schema

    assert [%{schema: @readable_schema, tool_revision: 2}] =
             Enum.filter(Services.definitions(context), &(&1.tool_name == @name))

    assert {:ok, ^document} = Services.call(context, @name, arguments)
    assert_receive {:readable_host_called, ^arguments, opts, nil}, 1_000
    assert opts[:allowed_hosts] == ["readable.example"]
    assert opts[:timeout] == 4_000
    assert opts[:result_limit] == 65_536
    assert opts[:proof_document] == document
    assert document |> Jason.encode!() |> Jason.decode!() == document
  end

  test "native Conversation commits the readable invocation and supplies its live effect deadline" do
    owner = self()
    run_id = "readable-native-#{System.unique_integer([:positive])}"
    url = "https://readable.example/native"
    arguments = %{"url" => url, "extract_mode" => "markdown", "max_chars" => 8192}
    document = document(url, "# Café article\n\nReadable **content**.")

    script = fn request ->
      case Enum.filter(request.messages, &(&1.role == :tool)) do
        [] ->
          [Proof.call(@name, arguments), Proof.completed("Reading")]

        [message] ->
          send(owner, {:readable_provider_result, message})
          [Proof.completed("Article read")]
      end
    end

    options = Proof.options(run_id, script, effect_timeout: 5_000, run_timeout: 15_000)
    context = readable_context(url, document)

    context =
      Map.update!(context, :web_fetch_options, &Keyword.put(&1, :proof_store, options[:context]))

    bundle = profile!(context, run_id, 2)
    descriptor = bundle.registry.tools[@name]
    assert descriptor.schema == @readable_schema
    assert descriptor.tool_revision == 2
    assert descriptor.backend == Backend

    options =
      Keyword.merge(options,
        registry: bundle.registry,
        tools: bundle.tools,
        authority: bundle.authority
      )

    conversation = start_supervised!({Conversation, options})
    caller = start_supervised!(Task.Supervisor)
    assert {:ok, _} = Proof.prompt(caller, conversation, "Read the article")
    assert_receive {:readable_host_called, ^arguments, opts, observation}, 5_000

    identity = observation.runtime.identity

    operation =
      observation.committed.run.execution_intents["tool:" <> identity.invocation_id].operation

    fields =
      ~w(run_id incarnation turn_id step_id attempt_id invocation_id tool_name tool_revision catalog_revision tool_call_id enclosing_invocation_id session_binding_identity)a

    assert identity == Map.take(operation, fields)
    assert identity.run_id == run_id
    assert identity.tool_name == @name
    assert identity.tool_revision == 2
    assert identity.tool_call_id == "call-1"
    assert operation.arguments == arguments
    assert observation.committed.revision > 0
    assert observation.effect_owner_alive
    assert is_function(observation.runtime.effect_deadline, 0)

    assert {{:ok, first}, {:ok, second}} = observation.deadlines
    assert first.selected_timeout_ms == 5_000
    assert first.paused == false
    assert is_integer(first.deadline_ms)
    assert first.remaining_ms > 0
    assert second.deadline_ms == first.deadline_ms
    assert second.remaining_ms > 0
    assert second.remaining_ms <= first.remaining_ms
    assert opts[:timeout] > 0
    assert opts[:timeout] <= 4_000

    expected = Map.put(document, :is_error, false)
    assert_receive {:readable_provider_result, message}, 5_000
    assert message.tool_call_id == "call-1"
    assert message.invocation_id == identity.invocation_id
    assert message.result == expected
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
    status = await_completed(conversation, System.monotonic_time(:millisecond) + 5_000)
    assert status.run.tool_results[identity.invocation_id] == expected
    assert {:ok, saved} = EphemeralStore.load(options[:context], run_id)
    assert saved.run.tool_results[identity.invocation_id] == expected
    assert Process.alive?(observation.adapter_pid) == false
    assert Process.alive?(observation.supervisor) == false
  end

  defp readable_context(url, document) do
    %{
      web_allowed_hosts: [URI.parse(url).host],
      web_fetch_adapter: HostReadableAdapter,
      web_timeout: 4_000,
      web_result_limit: 65_536,
      web_fetch_options: [proof_pid: self(), proof_document: document]
    }
  end

  defp document(url, text) do
    %{
      "url" => url,
      "final_url" => url <> "?view=readable",
      "text" => text,
      "content_type" => "text/html; charset=utf-8",
      "title" => "Café article",
      "excerpt" => "A readable document",
      "extractor" => "host-fixture",
      "truncated" => false,
      "cache" => %{"hit" => true, "source" => "host", "age_seconds" => 12},
      "metadata" => %{"authors" => ["Ada", "高"], "score" => 0.75, "published" => nil}
    }
  end

  defp profile!(context, run_id, revision) do
    authority = %{
      caller: "synapsis-readable-proof",
      run_id: run_id,
      grants: [@name],
      tool_revision: revision,
      tool_revisions: %{@name => revision}
    }

    assert {:ok, bundle} = Codex.profile(:service_compat, context, authority, tools: [@name])
    bundle
  end

  defp await_completed(conversation, deadline) do
    case Conversation.status(conversation) do
      %{phase: :terminal, run: %{state: :completed}, resource_cleanup: :confirmed} = status ->
        status

      status ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(status)
        Process.sleep(5)
        await_completed(conversation, deadline)
    end
  end
end
