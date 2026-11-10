defmodule Synapsis.Agent.Tools.MCPResourceScopeFunctionalTest do
  use ExUnit.Case, async: false
  @moduletag :functional

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{DynamicRuntime, Session}
  alias Backplane.McpProtocol.Client

  @version "2026-07-28"
  @cursor "opaque/first+雪?label=é"
  @uri "mem://selected/雪?part=é+1"
  @names ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource)

  # This adapter qualifies the public upstream scope contract. It deliberately
  # does not call Synapsis.MCP or install a model-facing host resource adapter.
  defmodule Adapter do
    alias Backplane.AgentRuntime.Codex.DynamicRuntime
    alias Backplane.McpProtocol.Client

    def list_resources(arguments, operation), do: request(arguments, operation, :list)

    def list_resource_templates(arguments, operation),
      do: request(arguments, operation, :templates)

    def read_resource(arguments, operation), do: request(arguments, operation, :read)

    defp request(arguments, operation, kind) do
      context = operation.backend_context

      DynamicRuntime.resource_request_scope(operation, fn scope ->
        Enum.reduce_while(context.scope_clients, {:ok, []}, fn {source, client}, {:ok, pages} ->
          response =
            DynamicRuntime.resource_request(scope, fn reserved ->
              source_options = [
                meta: %{"synapsis/scope" => %{"source" => source, "label" => "雪\r\n🎥"}}
              ]

              options = Keyword.merge(source_options, reserved)

              result =
                case kind do
                  :list ->
                    Client.start_list_resources(
                      client,
                      Keyword.put(options, :cursor, arguments["cursor"])
                    )

                  :templates ->
                    Client.start_list_resource_templates(
                      client,
                      Keyword.put(options, :cursor, arguments["cursor"])
                    )

                  :read ->
                    Client.start_read_resource(client, arguments["uri"], options)
                end

              case result do
                {:ok, handle} ->
                  send(
                    context.scope_observer,
                    {:scope_started, source, self(), handle.owner, handle.client, options}
                  )

                _ ->
                  :ok
              end

              result
            end)

          case response do
            {:ok, response} ->
              {:cont, {:ok, pages ++ [%{server: source, result: response.result}]}}

            error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, pages} -> {:ok, %{sources: pages}}
          error -> error
        end
      end)
    end
  end

  defmodule Provider do
    def stream(request, %{observer: observer}) do
      send(observer, {:scope_provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  for {name, method} <- [
        {"list_mcp_resources", "resources/list"},
        {"list_mcp_resource_templates", "resources/templates/list"},
        {"read_mcp_resource", "resources/read"}
      ] do
    @tag resource_tool: name, resource_method: method
    test "#{name} preserves two HTTP source results under one native invocation", context do
      sources = Enum.map(["source-a", "source-b"], &start_source/1)
      clients = Enum.map(sources, &{&1.source, &1.client})
      dynamic = start_supervised!({DynamicRuntime, mcp_adapter: Adapter})
      session = start_supervised!({Session, owner_pid: self()})

      authority = %{
        caller: "scope-fixture",
        run_id: "scope-run",
        grants: @names,
        tool_revision: 1
      }

      assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

      assert {:ok, profile} =
               Codex.profile(
                 :dynamic,
                 %{dynamic_runtime: dynamic, session_binding: binding},
                 authority,
                 tools: @names
               )

      descriptors =
        Enum.map(@names, fn name ->
          descriptor = Map.fetch!(profile.registry.tools, name)

          context =
            Map.merge(descriptor.backend_context, %{
              scope_clients: clients,
              scope_observer: self()
            })

          %{descriptor | backend_context: context}
        end)

      assert {:ok, admitted} =
               ToolCatalog.admit_batch(descriptors,
                 mode: :strict,
                 authority: profile.authority,
                 run_id: authority.run_id
               )

      assert {:ok, store} = EphemeralStore.new(1)

      conversation =
        start_supervised!(
          {Conversation,
           run_id: "scope-run",
           incarnation: 1,
           session_binding: binding,
           registry: admitted.registry,
           tools: admitted.tools,
           authority: admitted.authority,
           store: EphemeralStore,
           context: store,
           provider: Provider,
           provider_context: %{observer: self()},
           run_timeout: 20_000,
           effect_timeout: 10_000,
           cleanup_timeout: 2_000}
        )

      assert {:ok, _} = Conversation.prompt(conversation, "read selected fixture sources")
      assert_receive {:scope_provider, first_request, provider}, 2_000
      assert Enum.sort(Enum.map(first_request.tools, & &1.name)) == Enum.sort(@names)

      arguments =
        if context.resource_tool == "read_mcp_resource",
          do: %{"server" => "selected-fixtures", "uri" => @uri},
          else: %{"cursor" => @cursor}

      send(
        provider,
        {:events,
         [
           %{
             type: :tool_call_completed,
             tool_call: %{
               id: "scope-call",
               name: context.resource_tool,
               arguments: arguments
             }
           },
           done()
         ]}
      )

      assert_receive {:scope_provider, next_request, next_provider}, 6_000
      result = next_request.messages |> Enum.reverse() |> Enum.find(&(&1[:role] == :tool))

      assert result.result == %{
               is_error: false,
               sources:
                 Enum.map(sources, fn source ->
                   %{server: source.source, result: page(source.source, context.resource_method)}
                 end)
             }

      [{first_source, _}, {second_source, _}] = clients

      assert_receive {:scope_started, ^first_source, owner, owner, first_client, first_opts},
                     1_000

      assert_receive {:scope_started, ^second_source, ^owner, ^owner, second_client, second_opts},
                     1_000

      assert first_client == hd(sources).client_pid
      assert second_client == List.last(sources).client_pid
      assert first_opts[:retirement_deadline] == second_opts[:retirement_deadline]

      for options <- [first_opts, second_opts] do
        assert options[:track_retirement] == true
        assert options[:timeout] > 0 and options[:timeout] <= 10_000
        assert options[:registration_timeout] > 0 and options[:registration_timeout] <= 5_000
      end

      for source <- sources do
        source_id = source.source
        method = context.resource_method
        assert_receive {:scope_http, ^source_id, ^method, params, headers}, 1_000
        assert params["_meta"]["synapsis/scope"] == %{"source" => source_id, "label" => "雪\r\n🎥"}
        assert params["_meta"]["io.modelcontextprotocol/protocolVersion"] == @version
        assert headers["mcp-method"] == method

        if method == "resources/read",
          do: assert(params["uri"] == @uri),
          else: assert(params["cursor"] == @cursor)

        assert Process.alive?(source.client_pid)
        Gaoxy.Test.verify!(source.fixture)
      end

      send(next_provider, {:events, [done()]})
      await_completed(conversation, System.monotonic_time(:millisecond) + 3_000)
      assert {:ok, %{status: :confirmed}} = Session.close(session)
    end
  end

  defp start_source(source) do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    observer = self()

    Gaoxy.Test.stub(fixture, "GET", "/mcp", &Plug.Conn.resp(&1, 405, ""))
    Gaoxy.Test.stub(fixture, "DELETE", "/mcp", &Plug.Conn.resp(&1, 204, ""))

    Gaoxy.Test.stub(fixture, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      wire = Jason.decode!(body)

      send(
        observer,
        {:scope_http, source, wire["method"], wire["params"], Map.new(conn.req_headers)}
      )

      if Map.has_key?(wire, "id") do
        result =
          case wire["method"] do
            "server/discover" ->
              %{
                "resultType" => "complete",
                "supportedVersions" => [@version],
                "capabilities" => %{"resources" => %{}},
                "ttlMs" => 0,
                "cacheScope" => "private"
              }

            method ->
              page(source, method)
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => wire["id"], "result" => result})
        )
      else
        Plug.Conn.resp(conn, 202, "")
      end
    end)

    name = String.to_atom("SynapsisResourceScope#{System.unique_integer([:positive])}")

    start_supervised!(
      Supervisor.child_spec(
        {Client,
         name: name,
         transport: {:streamable_http, url: Gaoxy.Test.url(fixture, "/mcp")},
         one_shot: true,
         activation_id: "resource-scope-#{name}",
         client_info: %{"name" => "synapsis-resource-scope", "version" => "1"},
         capabilities: %{},
         protocol_version: @version,
         timeout: 3_000},
        id: {:scope_client, source}
      )
    )

    assert :ok = Client.await_ready(name, timeout: 3_000)
    assert_receive {:scope_http, ^source, "server/discover", _, _}, 3_000
    %{source: source, fixture: fixture, client: name, client_pid: Process.whereis(name)}
  end

  defp page(source, method) do
    shared = %{
      "_meta" => %{"synapsis/source" => source, "nested" => [true, nil, %{"雪" => "é"}]},
      "extra_result" => %{"label" => "原样\r\n🎥", "source" => source}
    }

    case method do
      "resources/list" ->
        Map.merge(shared, %{
          "resources" => [
            %{"uri" => @uri, "name" => "#{source} 雪", "mimeType" => "text/plain"},
            %{"uri" => "mem://#{source}/blob", "name" => "binary", "size" => 4}
          ],
          "nextCursor" => "#{source}/next+雪?opaque=é"
        })

      "resources/templates/list" ->
        Map.merge(shared, %{
          "resourceTemplates" => [
            %{
              "uriTemplate" => "mem://#{source}/{path}",
              "name" => "#{source} template 雪",
              "mimeType" => "application/octet-stream"
            }
          ],
          "nextCursor" => "#{source}/templates+雪?opaque=é"
        })

      "resources/read" ->
        Map.put(shared, "contents", [
          %{"uri" => @uri, "mimeType" => "text/plain", "text" => "#{source}\r\n雪 🎥"},
          %{"uri" => @uri, "mimeType" => "application/octet-stream", "blob" => "AAECAw=="}
        ])
    end
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}

  defp await_completed(conversation, deadline) do
    case Conversation.status(conversation) do
      %{phase: :terminal, run: %{state: :completed}} ->
        :ok

      status ->
        assert System.monotonic_time(:millisecond) < deadline, inspect(status)
        Process.sleep(10)
        await_completed(conversation, deadline)
    end
  end
end
