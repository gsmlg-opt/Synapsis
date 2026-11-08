defmodule Synapsis.Agent.Tools.ProcessInspectionFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.{Commands, Session}
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Synapsis.Agent.Tools.{NativeLocal, ProcessInspection}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @name "synapsis::process"
  @actions ~w(list inspect log poll remove clear_finished)

  test "explicit selection admits the six native inspection actions as one revision-one effect",
       %{
         tmp_dir: root
       } do
    fixture = fixture(root)
    assert ProcessInspection.names() == [@name]

    assert {:ok, []} =
             ProcessInspection.bundles(fixture.local, fixture.identity, fixture.authority, [])

    descriptor = fixture.descriptor
    assert descriptor.tool_name == @name
    assert descriptor.tool_revision == 1
    assert descriptor.backend == ProcessInspection
    assert descriptor.safety == %{read_only: false, retry_safe: false, parallel_safe: false}
    assert descriptor.schema["type"] == "object"
    assert descriptor.schema["additionalProperties"] == false
    assert descriptor.schema["required"] == ["action"]
    assert descriptor.schema["properties"]["action"]["enum"] == @actions

    assert {:ok, %{action: action, resource: resource}} =
             ProcessInspection.classify(
               descriptor,
               fixture.identity,
               operation(fixture, @name, %{"action" => "list"})
             )

    assert is_binary(action) and action != ""
    assert is_binary(resource) and resource != ""
    assert :ok = Session.prepare_detach(fixture.binding)
    assert {:ok, %{status: :retained}} = Session.detach(fixture.binding)
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)
  end

  test "real native command records preserve arbitrary bytes and independent poll delivery", %{
    tmp_dir: root
  } do
    fixture = fixture(root)

    assert LocalCommand.capabilities(fixture.runtime.command).stdin_close == %{
             pipe: true,
             pty: false
           }

    input = %{
      "cmd" =>
        "while [[ ! -f emit.gate ]]; do #{System.find_executable("sleep")} 0.01; done; printf '雪\\n'; printf ready > emitted; while IFS= read -r line; do :; done; printf 'after-eof\\n'",
      "shell" => "/bin/bash",
      "login" => false,
      "tty" => false,
      "yield_time_ms" => 0
    }

    assert {:ok, started} = native(fixture, "exec_command", input)
    id = started.session_id
    assert started.command_id == id
    File.touch!(Path.join(root, "emit.gate"))
    await(fn -> File.read(Path.join(root, "emitted")) == {:ok, "ready"} end)
    assert {:ok, owner} = Session.validate(fixture.binding, operation(fixture, @name, %{}))
    public_context = Map.put(fixture.local, :resource_owner, owner)
    await(fn -> match?({:ok, %{output: "雪\n"}}, Commands.log(public_context, id)) end)

    assert {:ok, records} = Commands.list(public_context)
    assert [%{command_id: ^id, finalized: false, status: :running}] = records
    assert host(fixture, %{"action" => "list"}) == payload("list", portable(records))
    assert {:ok, record} = Commands.inspect(public_context, id)

    assert host(fixture, %{"action" => "inspect", "command_id" => id}) ==
             payload("inspect", portable(record))

    assert {:ok, bytes} = Commands.log(public_context, id, cursor: 1)
    assert bytes.output == <<155, 170, 10>>
    expected = payload("log", portable_output(bytes))
    assert host(fixture, %{"action" => "log", "command_id" => id, "cursor" => 1}) == expected
    assert host(fixture, %{"action" => "log", "command_id" => id, "cursor" => 1}) == expected
    assert expected["result"]["output_base64"] == "m6oK"
    assert Map.has_key?(expected["result"], "output_text") == false

    assert {:ok, whole} = Commands.log(public_context, id)
    assert whole.output == "雪\n"

    assert host(fixture, %{"action" => "poll", "command_id" => id}) ==
             payload("poll", portable_output(whole))

    assert {:ok, empty} = Commands.log(public_context, id, cursor: 4)

    assert host(fixture, %{"action" => "poll", "command_id" => id}) ==
             payload("poll", portable_output(empty))

    assert empty.output == ""

    # Inspection reads have not advanced the original native delivery cursor.
    assert {:ok, delivery} =
             native(fixture, "write_stdin", %{"session_id" => id, "yield_time_ms" => 0})

    assert delivery.output == "雪\n"

    assert {:ok, completed} =
             native(fixture, "write_stdin", %{
               "session_id" => id,
               "eof" => true,
               "yield_time_ms" => 1000
             })

    assert completed.output == "after-eof\n"
    assert completed.command_id == id
    assert completed.status == :completed
    assert completed.exit_code == 0
    assert completed.cleanup_status == :confirmed

    assert {:ok, final} = Commands.inspect(public_context, id)
    assert final.finalized == true

    assert host(fixture, %{"action" => "inspect", "command_id" => id}) ==
             payload("inspect", portable(final))

    assert host(fixture, %{"action" => "remove", "command_id" => id}) ==
             payload("remove", %{"removed" => true, "command_id" => id})

    assert host(fixture, %{"action" => "clear_finished"}) ==
             payload("clear_finished", %{"removed" => 0})

    assert host(fixture, %{"action" => "list"}) == payload("list", [])
    assert :ok = Session.prepare_detach(fixture.binding)
    assert {:ok, %{status: :retained}} = Session.detach(fixture.binding)
    assert {:ok, %{status: :confirmed}} = Session.close(fixture.session)
  end

  defp fixture(root) do
    names = [@name, "exec_command", "write_stdin"]

    identity = %{
      caller: "process-inspection-positive",
      session_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      incarnation: 1,
      catalog_revision: 1
    }

    authority = %{
      caller: identity.caller,
      run_id: identity.run_id,
      grants: names,
      tool_revision: 1,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)
    server = start_supervised!({LocalCommand, name: nil, pty: true, pipe_stdin: true})

    assert {:ok, command} =
             Command.new(%{
               adapter: LocalCommand,
               server: server,
               allowed_environment: %{},
               job_limit: 16,
               output_limit: 262_144,
               deadline_limit: 300_000
             })

    local = %{
      workspace: root,
      caller: %{run_id: identity.run_id},
      command: command,
      session_registry: binding.resource_registry,
      session_binding: binding
    }

    assert {:ok, [host]} = ProcessInspection.bundles(local, identity, authority, [@name])

    assert {:ok, [native]} =
             NativeLocal.bundles(local, authority, ["exec_command", "write_stdin"])

    assert {:ok, catalog} =
             ToolCatalog.admit_batch(
               Map.values(host.registry.tools) ++ Map.values(native.registry.tools),
               authority: authority,
               mode: :strict
             )

    assert :ok = Session.attach(binding, Map.put(catalog, :revision, 1))

    %{
      identity: identity,
      authority: authority,
      session: session,
      binding: binding,
      local: local,
      runtime: %{command: command, server: server},
      descriptor: host.registry.tools[@name],
      native: native.registry.tools
    }
  end

  defp operation(fixture, name, arguments) do
    descriptor = if name == @name, do: fixture.descriptor, else: fixture.native[name]

    %{
      tool_name: name,
      tool_revision: 1,
      run_id: fixture.identity.run_id,
      incarnation: 1,
      catalog_revision: 1,
      caller: fixture.identity.caller,
      invocation_id: Ecto.UUID.generate(),
      arguments: arguments,
      backend_context: descriptor.backend_context
    }
  end

  defp native(fixture, name, args),
    do: fixture.native[name].backend.execute(operation(fixture, name, args))

  defp host(fixture, args) do
    assert {:ok, output} = ProcessInspection.execute(operation(fixture, @name, args))
    assert Jason.decode!(output.content) == output.structured
    output.structured
  end

  defp portable(value), do: value |> Jason.encode!() |> Jason.decode!()
  defp payload(action, result), do: %{"action" => action, "result" => result}

  defp portable_output(value) do
    output = value.output

    value =
      value
      |> Map.delete(:output)
      |> portable()
      |> Map.put("output_base64", Base.encode64(output))

    if String.valid?(output), do: Map.put(value, "output_text", output), else: value
  end

  defp await(check), do: await(check, System.monotonic_time(:millisecond) + 5_000)

  defp await(check, deadline) do
    unless check.() do
      assert System.monotonic_time(:millisecond) < deadline,
             "ordinary command emission did not arrive"

      Process.sleep(10)
      await(check, deadline)
    end
  end
end
