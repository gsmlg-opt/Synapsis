defmodule Synapsis.Agent.Tools.Workflows do
  @moduledoc """
  Explicitly selected pure inline workflows with durable structured-input checkpoints.

  The native Session owns each invocation, deadline and helper retirement. The
  existing Segment driver owns acknowledged continuation transitions. Public
  results contain only the normalized envelope, never snapshots or host state.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.Agent.Tools.Workflows.Segment
  alias Synapsis.{AgentConfig, AgentConfigs}
  alias Synapsis.Filesystem.Local
  alias Synapsis.Workflow.Pipeline
  alias Synapsis.Workflow.Segment, as: CoreSegment

  @name "synapsis::lobster"
  @keys ~w(identity agent_id agent_name fingerprint profiles_context session_binding project_root schema_runtime)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @commands ~w(head pick json ask sort dedupe groupBy map where table)

  def names, do: [@name]
  def permission_level(@name), do: :execute

  def bundles(context, identity, authority, selection, binding) do
    if @name in selection do
      with true <- @name in authority.grants,
           {:ok, agent} <- configuration(context.agent[:id], context.agent[:name]),
           true <- context.session.id === identity.session_id,
           {:ok, root, _} <- Local.resolve(context.project_path, "."),
           {:ok, runtime} <- schema_runtime(),
           trusted = %{
             identity: identity,
             agent_id: agent.id,
             agent_name: agent.name,
             fingerprint: fingerprint(agent),
             profiles_context: Map.take(context, [:session, :agent, :project_path]),
             session_binding: binding,
             project_root: root,
             schema_runtime: runtime
           },
           ceiling = %{
             authority
             | grants: [@name],
               tool_revisions: Map.take(authority.tool_revisions, [@name])
           },
           {:ok, bundle} <-
             ToolCatalog.admit_batch([descriptor(trusted)], authority: ceiling, mode: :strict) do
        {:ok, [bundle]}
      else
        false -> failure(:forbidden, "Workflow exceeds its original Agent or Session scope")
        {:error, %Error{}} = error -> error
        _ -> failure(:unsupported_capability, "Workflow configuration is unavailable")
      end
    else
      {:ok, []}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, input} <- invocation(context, operation) do
      resource =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({context.agent_id, identity.session_id, input}, [:deterministic])
        )
        |> Base.encode16(case: :lower)

      {:ok, %{action: "workflow." <> input.action, resource: "workflow:" <> resource}}
    else
      false -> failure(:forbidden, "Workflow invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "Workflow descriptor is unavailable")

  def tool_effect_timeout(%{tool_name: @name, tool_revision: 1} = invocation, %{
        catalog_snapshot: %{registry: registry}
      }) do
    with {:ok, %{backend: __MODULE__, tool_revision: 1}} <- ToolRegistry.lookup(registry, @name),
         {:ok, timeout} <- timeout(invocation.arguments) do
      {:ok, timeout}
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "Workflow timing descriptor is unavailable")
    end
  end

  def tool_effect_timeout(%{tool_name: @name}, _),
    do: failure(:validation, "Workflow timing descriptor is unavailable")

  def tool_effect_timeout(_, _), do: :default

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    context = Map.take(enriched, @keys)

    with {:ok, input} <- invocation(context, operation) do
      trusted = %{
        profiles_context: context.profiles_context,
        session_id: context.identity.session_id,
        caller: context.identity.caller,
        operation: operation,
        session_binding: context.session_binding,
        schema_runtime: context.schema_runtime,
        project_root: context.project_root
      }

      result =
        case input do
          %{action: "run", pipeline: pipeline, file_scope: scope} ->
            Segment.run(pipeline, Map.put(trusted, :file_scope, scope))

          %{action: "resume", id: id, revision: revision, response: response} ->
            Segment.resume(id, revision, response, trusted)
        end

      case result do
        {:ok, outcome} -> output(outcome, input.max_bytes)
        {:error, problem} -> segment_failure(problem)
      end
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:validation, "Workflow invocation is unavailable")
    end
  rescue
    _ -> failure(:unknown_outcome, "Workflow outcome could not be observed; it was not replayed")
  catch
    :exit, _ ->
      failure(:unknown_outcome, "Workflow outcome could not be observed; it was not replayed")
  end

  def execute(_), do: failure(:validation, "Workflow context is unavailable")

  @impl true
  # Native effect termination and the registered helper owner retain cleanup.
  def cancel(_operation), do: :ok

  defp invocation(context, operation) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- operation[:tool_name] === @name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         {:ok, agent} <- configuration(context.agent_id, context.agent_name),
         true <- fingerprint(agent) === context.fingerprint,
         true <- context.profiles_context.agent.id === context.agent_id,
         true <- context.profiles_context.agent.name === context.agent_name,
         true <- context.profiles_context.session.id === context.identity.session_id,
         {:ok, runtime} <- schema_runtime(),
         true <- runtime === context.schema_runtime,
         {:ok, arguments} <- InputSchema.validate(schema(), operation.arguments),
         {:ok, input} <- normalize(arguments, context.project_root) do
      {:ok, input}
    else
      false -> failure(:forbidden, "Workflow configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "Workflow invocation is unavailable")
    end
  end

  defp normalize(arguments, root) do
    cwd = String.trim(Map.get(arguments, "cwd", ""))
    cwd = if cwd == "", do: ".", else: cwd

    with true <- Path.type(cwd) == :relative,
         {:ok, _cwd, relative_cwd} <- Local.resolve(root, cwd),
         {:ok, _} <- timeout(arguments),
         false <- Enum.any?(~w(approvalId approve cancel), &Map.has_key?(arguments, &1)),
         {:ok, input} <- action(arguments) do
      input =
        if input.action == "run",
          do: Map.put(input, :file_scope, %{"project_root" => root, "cwd" => relative_cwd}),
          else: input

      {:ok, Map.put(input, :max_bytes, max(1024, Map.get(arguments, "maxStdoutBytes", 512_000)))}
    else
      true ->
        failure(
          :unsupported_capability,
          "Workflow approvals and checkpoint cancellation are not implemented"
        )

      false ->
        failure(:validation, "Workflow cwd must be relative to the project root")

      {:error, %Error{}} = error ->
        error

      _ ->
        failure(:validation, "Workflow cwd must resolve within the project root")
    end
  end

  defp action(%{"action" => "run", "pipeline" => pipeline}) do
    pipeline = String.trim(pipeline)

    with {:ok, program} <- Pipeline.parse(pipeline),
         true <- Enum.all?(program, &(&1["name"] in @commands)) do
      # Inline argsJson is intentionally ignored, as in the pinned runner.
      {:ok, %{action: "run", pipeline: pipeline}}
    else
      false ->
        failure(
          :unsupported_capability,
          "Workflow supports pure inline commands only; files and effects are not implemented"
        )

      _ ->
        failure(:validation, "Workflow pipeline must be a nonempty inline pipeline")
    end
  end

  defp action(%{"action" => "resume", "token" => token, "responseJson" => response}) do
    with "workflow-segment.v1." <> encoded <- String.trim(token),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"workflowId" => id, "revision" => revision} = locator} <- Jason.decode(json),
         true <- map_size(locator) == 2 and is_integer(revision) and revision > 0,
         {:ok, ^id} <- Ecto.UUID.cast(id) do
      {:ok, %{action: "resume", id: id, revision: revision, response: response}}
    else
      _ -> failure(:validation, "Workflow resume requires its structured-input token")
    end
  end

  defp action(_),
    do: failure(:validation, "Workflow requires a pipeline or a token and responseJson")

  defp timeout(arguments) do
    case Map.get(arguments, "timeoutMs", 20_000) do
      value when is_integer(value) and value in 1..2_147_483_647 ->
        {:ok, max(200, value)}

      value when is_integer(value) and value > 2_147_483_647 ->
        failure(
          :unsupported_capability,
          "Workflow timeoutMs exceeds the supported native timer range"
        )

      _ ->
        failure(:validation, "Workflow timeoutMs must be a positive integer")
    end
  end

  defp output(outcome, max_bytes) do
    token = get_in(outcome.envelope, ["requiresInput", "resumeToken"])

    with {:ok, %{text: text, envelope: envelope}} <-
           CoreSegment.render_envelope(outcome.record.snapshot, token),
         true <- byte_size(text) <= max_bytes,
         result = %{content: [%{type: "text", text: text}], details: envelope},
         {:ok, _} <- ToolEffects.validate_output(%{payload: result}) do
      {:ok, result}
    else
      false ->
        acknowledged_failure(
          :budget_exceeded,
          "Workflow result exceeded maxStdoutBytes",
          outcome.record
        )

      {:error, %Error{class: :resource_conflict}} ->
        acknowledged_failure(
          :budget_exceeded,
          "Workflow result exceeds the native result budget",
          outcome.record
        )

      _ ->
        acknowledged_failure(
          :malformed_result,
          "Workflow public envelope could not be rendered",
          outcome.record
        )
    end
  rescue
    _ ->
      acknowledged_failure(
        :malformed_result,
        "Workflow public envelope could not be rendered",
        outcome.record
      )
  end

  defp segment_failure(%{stage: stage, reason: reason, record: record}) do
    class =
      cond do
        reason in [:timeout, :resource_conflict, :not_found] -> reason
        reason in [:unknown_outcome, :helper_cleanup_unconfirmed] -> :unknown_outcome
        stage in [:helper_close, :resource_release, :retirement] -> :unknown_outcome
        true -> :execution_failure
      end

    acknowledged_failure(
      class,
      "Workflow segment could not complete; it was not replayed",
      record,
      %{"stage" => to_string(stage)}
    )
  end

  defp segment_failure(_),
    do: failure(:unknown_outcome, "Workflow outcome could not be confirmed")

  defp acknowledged_failure(class, message, record, details \\ %{}) do
    details =
      case record do
        %{id: id, revision: revision} ->
          Map.put(details, "acknowledgedContinuation", %{
            "workflowId" => id,
            "revision" => revision
          })

        _ ->
          details
      end

    {:error, Error.new(class, message, details: details)}
  end

  defp configuration(id, name) do
    case AgentConfigs.get(id) do
      %AgentConfig{id: ^id, name: ^name, enabled: true} = agent -> {:ok, agent}
      _ -> failure(:unsupported_capability, "Workflow requires its original enabled Agent")
    end
  end

  defp fingerprint(agent),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({agent.id, agent.name, agent.tools, agent.tool_contract_version}, [
          :deterministic
        ])
      )

  defp schema_runtime do
    with node when is_binary(node) <- Application.get_env(:synapsis_agent, :filesystem_node),
         priv when is_list(priv) <- :code.priv_dir(:synapsis_core),
         helper = Path.join(priv, "workflow_schema/schema-stdio.mjs"),
         true <- absolute_file?(node) and absolute_file?(helper) do
      {:ok, %{node_executable: node, helper_path: helper}}
    else
      _ ->
        failure(
          :unsupported_capability,
          "Workflow requires the configured Node executable and packaged schema helper"
        )
    end
  end

  defp absolute_file?(path),
    do:
      String.valid?(path) and not String.contains?(path, <<0>>) and Path.type(path) == :absolute and
        File.regular?(path)

  defp descriptor(context) do
    %{
      tool_name: @name,
      tool_revision: 1,
      description:
        "Run pure inline Lobster workflows with head, pick, json, ask, sort, dedupe, groupBy, map, where and table. Structured input returns needs_input: ask the returned prompt, then explicitly resume with its token and responseJson matching responseSchema. Workflow files, external effects, approvals and checkpoint cancellation are not implemented. Inline argsJson is ignored. timeoutMs defaults to 20000 (minimum effective 200; maximum 2147483647); maxStdoutBytes defaults to 512000 (minimum effective 1024) and counts the complete pretty JSON envelope.",
      schema: schema(),
      safety: %{read_only: false, retry_safe: false, parallel_safe: false},
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp schema do
    %{
      "type" => "object",
      "required" => ["action"],
      "properties" => %{
        "action" => %{"enum" => ["run", "resume"], "type" => "string"},
        "pipeline" => %{"type" => "string"},
        "argsJson" => %{"type" => "string"},
        "token" => %{"type" => "string"},
        "approvalId" => %{"type" => "string"},
        "approve" => %{"type" => "boolean"},
        "responseJson" => %{
          "type" => "string",
          "description" =>
            "User's answer as JSON for an input checkpoint. Use instead of approve."
        },
        "cancel" => %{"type" => "boolean", "const" => true},
        "cwd" => %{
          "type" => "string",
          "description" =>
            "Relative working directory (optional). Must stay within the gateway working directory."
        },
        "timeoutMs" => %{"type" => "integer", "minimum" => 1},
        "maxStdoutBytes" => %{"type" => "integer", "minimum" => 1}
      }
    }
  end

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
