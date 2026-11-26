defmodule Synapsis.Agent.Tools.SkillCreate do
  @moduledoc "Explicit creation on one configured Backplane discovery source."
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema}
  alias Synapsis.Agent.Tools.{CatalogBinding, Skills}

  @name "synapsis::skills_create"
  @fields ~w(source_id slug name description content)
  @context_keys [:agent_id, :run_id, :incarnation, :catalog_revision]
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch nested_submit register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a

  def names, do: [@name]
  def permission_level(@name), do: :write

  def descriptors(context) do
    with :ok <- context_valid(context) do
      {:ok,
       [
         %{
           tool_name: @name,
           tool_revision: 1,
           description:
             "Create a skill on an explicitly configured Backplane source. Supply the lowercase hyphenated slug, display name, description and Markdown instruction body. Returns the published exact reference. Agent assignment and always-returned selection are managed separately.",
           schema: schema(),
           safety: %{read_only: false, retry_safe: false, parallel_safe: false},
           backend: __MODULE__,
           backend_context: context
         }
       ]}
    end
  end

  def classify(context, operation) do
    with :ok <- context_valid(context),
         :ok <- CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys),
         %{tool_name: @name, arguments: args} <- operation,
         {:ok, _} <- InputSchema.validate(schema(), args) do
      {:ok,
       %{
         action: "skill.write",
         resource:
           "skill:agent:#{context.agent_id}:source:backplane:#{args["source_id"]}:slug:#{args["slug"]}",
         permission_level: :write
       }}
    else
      {:error, reason} -> failure(reason)
      _ -> failure(:invalid_input)
    end
  end

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    with :ok <- enriched_context(enriched),
         context = Map.take(enriched, @context_keys),
         {:ok, _} <-
           classify(context, CatalogBinding.classification_operation(operation, context)),
         {:ok, opts} <- Skills.read_options(operation),
         module when is_atom(module) and not is_nil(module) <-
           Application.get_env(:synapsis_core, :skill_discovery) do
      deadline = Keyword.get(opts, :deadline, System.monotonic_time(:millisecond) + 5_000)
      owner = self()

      cancelled? = fn ->
        not Process.alive?(owner) or System.monotonic_time(:millisecond) >= deadline
      end

      args = operation.arguments

      result =
        module.create(
          context.agent_id,
          args["source_id"],
          Map.take(args, @fields -- ["source_id"]),
          timeout: max(1, deadline - System.monotonic_time(:millisecond)),
          cancelled?: cancelled?
        )

      case result do
        {:ok, receipt} ->
          {:ok,
           %{
             content:
               "Created Backplane skill #{receipt.skill_id} at revision #{receipt.revision}.",
             structured: receipt
           }}

        {:error, reason} ->
          failure(reason)
      end
    else
      {:error, reason} -> failure(reason)
      _ -> failure(:unsupported_capability)
    end
  end

  def execute(_), do: failure(:invalid_input)

  @impl true
  def cancel(_), do: :ok

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "source_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 128},
        "slug" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 64,
          "pattern" => "^[a-z0-9]+(-[a-z0-9]+)*$"
        },
        "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
        "description" => %{"type" => "string", "minLength" => 1, "maxLength" => 1024},
        "content" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_097_152}
      },
      "required" => @fields,
      "additionalProperties" => false
    }
  end

  defp enriched_context(context) when is_map(context) do
    if Map.keys(context) -- (@context_keys ++ @native_keys) == [],
      do: :ok,
      else: failure(:invalid_input)
  end

  defp enriched_context(_), do: failure(:invalid_input)

  defp context_valid(context) when is_map(context) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         match?({:ok, _}, Ecto.UUID.cast(context[:agent_id])) and
         is_binary(context[:run_id]) and byte_size(context.run_id) in 1..4096 and
         is_integer(context[:incarnation]) and context.incarnation > 0 and
         is_integer(context[:catalog_revision]) and context.catalog_revision > 0,
       do: :ok,
       else: failure(:invalid_input)
  end

  defp context_valid(_), do: failure(:invalid_input)

  defp failure(%Error{} = error), do: {:error, error}

  defp failure(reason) do
    class =
      case reason do
        code when code in [:invalid_input, :invalid_request, :invalid_document] ->
          :validation

        code when code in [:source_unavailable, :scope_mismatch, :forbidden, :unauthorized] ->
          :forbidden

        :already_exists ->
          :resource_conflict

        code when code in [:unsupported_capability, :unsupported_protocol] ->
          :unsupported_capability

        _ ->
          :unknown_outcome
      end

    {:error,
     Error.new(class, "Backplane skill creation failed", details: %{code: to_string(reason)})}
  end
end
