defmodule Synapsis.Agent.Tools.NativeLocal do
  @moduledoc """
  Builds original native local bundles and classifies their trusted host scope.

  Raw patches retain the pinned custom descriptor and backend. Public native
  preflight binds one opaque resource to the physical root, exact raw digest and
  every ordered source/destination fact, without embedding patch contents.
  Add/update/move require write; delete requires destructive; mixed patches
  require both through a host-only compound invocation target. Preflight repeats
  during policy refresh; it is not a transaction or a future filesystem snapshot.
  Native execution remains sequential and can report partial effects.

  Image reads retain the pinned descriptor and backend. Public native path
  authorization supplies the filesystem read resource for host classification.
  """

  alias Backplane.AgentRuntime.{Codex, Command, Error, InputSchema}
  alias Backplane.AgentRuntime.Codex.{ApplyPatch, Backend, PathGuard, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Synapsis.Agent.Tools.ProcessInspection

  @names ~w(exec_command write_stdin clock::curr_time clock::sleep apply_patch view_image)
  @commands ~w(exec_command write_stdin)

  def names, do: @names
  def permission_level("apply_patch"), do: :destructive
  def permission_level("view_image"), do: :read
  def permission_level(name) when name in @commands, do: :execute
  def permission_level(name) when name in @names, do: :none

  def open(selection, runtime) do
    cond do
      is_map(runtime) and is_pid(runtime.server) and Process.alive?(runtime.server) ->
        {:ok, runtime}

      not Enum.any?(selection, &(&1 in @commands or &1 in ProcessInspection.names())) ->
        {:ok, nil}

      true ->
        with {:ok, server} <-
               LocalCommand.start_link(
                 name: nil,
                 pty: :os.type() == {:unix, :linux},
                 pipe_stdin: :os.type() == {:unix, :linux}
               ) do
          case Command.new(%{
                 adapter: LocalCommand,
                 server: server,
                 allowed_environment: %{},
                 job_limit: 16,
                 output_limit: 262_144,
                 deadline_limit: 300_000
               }) do
            {:ok, command} ->
              {:ok, %{server: server, command: command}}

            error ->
              GenServer.stop(server)
              error
          end
        end
    end
  end

  def bundles(context, authority, selection) do
    selected = Enum.filter(selection, &(&1 in @names))

    cond do
      selected == [] ->
        {:ok, []}

      not Enum.all?(selected, &(&1 in authority.grants)) ->
        {:error, Error.new(:forbidden, "Local tools exceed the parent authority ceiling")}

      true ->
        native_authority = %{
          authority
          | grants: selected,
            tool_revisions: Map.take(authority.tool_revisions, selected)
        }

        case Codex.profile(:pinned_local, context, native_authority, tools: selected) do
          {:ok, bundle} -> {:ok, [bundle]}
          error -> error
        end
    end
  end

  def classify(
        %{backend: Backend, backend_context: %{family: :local, context: context}} = descriptor,
        identity,
        invocation
      ) do
    with true <- descriptor.tool_name in @names,
         true <-
           invocation[:tool_name] === descriptor.tool_name and
             invocation[:tool_revision] === descriptor.tool_revision and
             context[:caller] === %{run_id: identity.run_id},
         :ok <- Synapsis.Agent.Tools.CatalogBinding.descriptor(descriptor, identity, invocation),
         {:ok, args} <- arguments(descriptor, invocation[:arguments]) do
      target(descriptor.tool_name, context, identity, args)
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  def classify(_, _, _), do: {:error, :unsupported_classification}

  defp arguments(%{tool_name: "apply_patch", codex_input_kind: :custom}, raw)
       when is_binary(raw),
       do: {:ok, raw}

  defp arguments(descriptor, args), do: InputSchema.validate(descriptor.schema, args)

  defp target("view_image", context, _identity, %{"path" => path}) do
    with {:ok, path} <- PathGuard.authorize(context.workspace, path) do
      {:ok, %{action: "filesystem.read", resource: "filesystem:" <> path}}
    end
  end

  defp target("apply_patch", context, _identity, raw) do
    with {:ok, inspected} <- ApplyPatch.preflight(context.workspace, raw) do
      operations = Enum.map(inspected.operations, &patch_fact/1)

      levels =
        Enum.filter([:write, :destructive], fn level ->
          Enum.any?(inspected.operations, fn operation ->
            if operation.kind == :delete, do: level == :destructive, else: level == :write
          end)
        end)

      {:ok,
       %{
         action: "filesystem.patch",
         resource:
           "filesystem:patch:" <>
             Jason.encode!([1, inspected.root, inspected.patch_sha256, operations]),
         permission_levels: levels
       }}
    end
  end

  defp target("exec_command", context, _identity, args) do
    with :ok <- command_available(context),
         {:ok, path} <-
           PathGuard.authorize(context.workspace, args["workdir"] || context.workspace) do
      {:ok, %{action: "command.execute", resource: "command:workspace:" <> path}}
    end
  end

  defp target("write_stdin", context, identity, %{"session_id" => id}) do
    with :ok <- command_available(context),
         {:ok, owner, incarnation} <- command_owner(context, identity),
         {:ok, _session} <-
           ResourceRegistry.fetch_session(context.session_registry, id, owner, incarnation) do
      {:ok,
       %{
         action: "command.stdin",
         resource: "command:session:" <> identity.session_id <> ":" <> Integer.to_string(id)
       }}
    end
  end

  defp target("clock::curr_time", _, _, _),
    do: {:ok, %{action: "clock.read", resource: "clock:utc"}}

  defp target("clock::sleep", _, _, _),
    do: {:ok, %{action: "clock.sleep", resource: "clock:local"}}

  defp patch_fact(%{kind: kind, path: path}) when kind in [:add, :delete],
    do: [Atom.to_string(kind), path]

  defp patch_fact(%{kind: kind, path: path, destination: destination})
       when kind in [:update, :move],
       do: [Atom.to_string(kind), path, destination]

  defp command_owner(%{session_binding: binding}, identity) do
    case Session.validate(binding, identity) do
      {:ok, owner} -> {:ok, owner.owner_id, owner.incarnation}
      error -> error
    end
  end

  defp command_owner(_context, identity), do: {:ok, identity.run_id, identity.incarnation}

  defp command_available(%{command: %{server: server}, session_registry: registry})
       when is_pid(server) and is_pid(registry) do
    if Process.alive?(server) and Process.alive?(registry),
      do: :ok,
      else: {:error, :command_unavailable}
  end

  defp command_available(_), do: {:error, :command_unavailable}
end
