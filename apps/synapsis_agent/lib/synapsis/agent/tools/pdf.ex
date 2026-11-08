defmodule Synapsis.Agent.Tools.PDF do
  @moduledoc """
  Selected PDF tool for configured and automatically resolved native and extraction models.

  Acquired bytes and lazy extraction results live only inside this invocation.
  Native Anthropic/Google candidates receive complete inline PDFs through the
  official protocol codec. Extraction helpers retain registered cleanup ownership.
  Only final analysis and bounded provenance enter native history.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.Tools.{CatalogBinding, PDF.Analysis, PDF.Context, PDF.Model}
  alias Synapsis.{AgentConfig, AgentConfigs}
  alias Synapsis.Filesystem.Local
  alias Synapsis.PDF.{PortSession, Source}

  @name "synapsis::pdf"
  @keys ~w(identity agent_id agent_name project_root fingerprint models model_context project_defaults selection_fingerprint session_binding)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @timeout 60_000
  @config_keys ~w(pdfModel imageModel pdfMaxMb pdfMaxPages pdfHost web_allowed_hosts)

  def names, do: [@name]
  def permission_level(@name), do: :read

  def bundles(context, identity, authority, selection, binding) do
    if @name in selection do
      with true <- @name in authority.grants,
           project_defaults = project_defaults(context),
           model_context = admitted_model_context(context, project_defaults),
           {:ok, agent, config, prepared} <- configuration(context.agent[:name], model_context),
           {:ok, root, _} <- Local.resolve(context.project_path, "."),
           trusted = %{
             identity: identity,
             agent_id: agent.id,
             agent_name: agent.name,
             project_root: root,
             fingerprint:
               fingerprint(
                 agent,
                 config,
                 root,
                 model_context,
                 project_defaults,
                 prepared.fingerprint
               ),
             models: prepared.models,
             selection_fingerprint: prepared.fingerprint,
             model_context: model_context,
             project_defaults: project_defaults,
             session_binding: binding
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
        false -> failure(:forbidden, "PDF exceeds the parent authority ceiling")
        {:error, %Error{}} = error -> error
        _ -> failure(:unsupported_capability, "PDF configuration is unavailable")
      end
    else
      {:ok, []}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, input, _config, _models} <- invocation(context, operation) do
      {:ok,
       %{
         action: "pdf.analyze",
         resource:
           "pdf:" <>
             Base.encode16(
               :crypto.hash(
                 :sha256,
                 :erlang.term_to_binary({context.agent_id, input}, [:deterministic])
               ),
               case: :lower
             ),
         permission_level: :read
       }}
    else
      false -> failure(:forbidden, "PDF invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "PDF descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    context = Map.take(enriched, @keys)

    with {:ok, input, config, candidates} <- invocation(context, operation) do
      execute_ready(input, config, candidates, context)
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:execution_failure, "PDF analysis is unavailable")
    end
  rescue
    _ -> failure(:unknown_outcome, "PDF work could not be observed")
  catch
    :exit, _ -> failure(:unknown_outcome, "PDF work could not be observed")
  end

  def execute(_), do: failure(:validation, "PDF context is unavailable")

  defp execute_ready(input, config, candidates, context) do
    deadline = now() + @timeout

    with true <- now() < deadline,
         {:ok, documents} <- acquire(input, context, config, deadline),
         {:ok, text, model, native, notices, attempts} <-
           analyze(
             candidates,
             documents,
             input,
             config,
             context.session_binding,
             deadline,
             nil,
             []
           ) do
      output(text, model, native, notices, documents, attempts)
    else
      {:error, %Error{}} = error ->
        error

      {:error, :unknown_outcome} ->
        failure(:unknown_outcome, "PDF work could not be confirmed; it was not replayed")

      _ ->
        failure(:execution_failure, "PDF analysis is unavailable")
    end
  end

  @impl true
  # The native execution boundary terminates the effect process. Each broker
  # separately monitors that caller, and each analysis task monitors its owner;
  # registered cleanup remains with the native Session, including uncertain exits.
  def cancel(_operation), do: :ok

  defp invocation(context, operation) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- operation[:tool_name] === @name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         model_context = current_model_context(context),
         {:ok, agent, config, current} <- configuration(context.agent_name, model_context),
         true <-
           agent.id === context.agent_id and
             fingerprint(
               agent,
               config,
               context.project_root,
               model_context,
               context.project_defaults,
               current.fingerprint
             ) === context.fingerprint,
         true <-
           current.fingerprint === context.selection_fingerprint and
             current.models === context.models,
         {:ok, arguments} <- InputSchema.validate(schema(), operation.arguments),
         {:ok, input} <- Context.normalize(arguments, config),
         {:ok, candidates} <- Model.resolve(config, arguments["model"], model_context) do
      {:ok, input, config, candidates}
    else
      false -> failure(:forbidden, "PDF configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "PDF invocation is unavailable")
    end
  end

  defp configuration(name, model_context) do
    with %AgentConfig{enabled: true, config: config} = agent <- AgentConfigs.get_by_name(name),
         true <- is_map(config),
         config = Map.take(config, @config_keys),
         {:ok, prepared} <- Model.prepare(config, model_context),
         true <-
           valid_host?(config["pdfHost"]) or
             (is_nil(config["pdfHost"]) and hd(prepared.models).native) do
      {:ok, agent, config, prepared}
    else
      _ ->
        failure(
          :unsupported_capability,
          "PDF requires an enabled Agent and explicit trusted pdfHost paths for extraction"
        )
    end
  end

  defp absolute_file?(path),
    do:
      is_binary(path) and String.valid?(path) and not String.contains?(path, <<0>>) and
        Path.type(path) == :absolute and File.regular?(path)

  defp project_defaults(context) do
    config =
      case Map.get(context, :session) do
        %{config: config} when is_map(config) -> config
        _ -> %{}
      end

    Map.take(config, ["agents"])
  end

  defp admitted_model_context(context, project_defaults) do
    supplied = Map.get(context, :pdf_model_context, %{})

    %{
      configured_default:
        Synapsis.Session.Worker.Config.configured_default_model(
          context.agent[:name],
          project_defaults
        ),
      active_model: Map.get(supplied, :active_model)
    }
  end

  defp current_model_context(context) do
    # In-flight project config and admitted active model remain the run's
    # authority. Only the saved Agent default is refreshed, without skill IO.
    Map.put(
      context.model_context,
      :configured_default,
      Synapsis.Session.Worker.Config.configured_default_model(
        context.agent_name,
        context.project_defaults
      )
    )
  end

  defp fingerprint(agent, config, root, model_context, project_defaults, selection_fingerprint),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {agent.id, agent.name, agent.tools, agent.provider, agent.model, agent.model_tier,
           config, root, model_context, project_defaults, selection_fingerprint},
          [:deterministic]
        )
      )

  defp valid_host?(%{"node_executable" => node, "helper_path" => helper}),
    do: absolute_file?(node) and absolute_file?(helper)

  defp valid_host?(_), do: false

  defp acquire(input, context, config, deadline) do
    source_context = %{
      project_root: context.project_root,
      web_allowed_hosts: config["web_allowed_hosts"] || []
    }

    Enum.reduce_while(input.references, {:ok, []}, fn reference, {:ok, documents} ->
      if now() < deadline do
        case Source.load(reference, source_context, input.max_bytes, deadline) do
          {:ok, document} -> {:cont, {:ok, documents ++ [document]}}
          _ -> {:halt, failure(:execution_failure, "PDF source acquisition failed")}
        end
      else
        {:halt, failure(:timeout, "PDF invocation timed out")}
      end
    end)
  end

  defp extract(documents, input, config, binding, deadline) do
    if valid_host?(config["pdfHost"]) do
      Enum.reduce_while(documents, {:ok, []}, fn document, {:ok, results} ->
        case extract_one(document.bytes, input, config, binding, deadline) do
          {:ok, result} -> {:cont, {:ok, results ++ [result]}}
          error -> {:halt, error}
        end
      end)
    else
      failure(:unsupported_capability, "PDF extraction requires explicit trusted pdfHost paths")
    end
  end

  defp extract_one(bytes, input, config, binding, deadline) do
    with true <- now() < deadline,
         {:ok, supervisor} <- ResourceRegistry.worker_supervisor(binding.resource_registry),
         {:ok, broker} <-
           DynamicSupervisor.start_child(
             supervisor,
             {PortSession,
              [
                owner_pid: binding.owner_pid,
                node_executable: config["pdfHost"]["node_executable"],
                helper_path: config["pdfHost"]["helper_path"]
              ]}
           ) do
      case ResourceRegistry.register(binding.resource_registry, binding.owner_id, :pdf, broker,
             incarnation: binding.incarnation,
             owner_pid: binding.owner_pid,
             cleanup: fn -> cleanup(supervisor, broker) end
           ) do
        {:ok, handle} ->
          result =
            try do
              options = %{maxPages: input.max_pages}

              options =
                if input.page_numbers,
                  do: Map.put(options, :pageNumbers, input.page_numbers),
                  else: options

              options =
                if input.password, do: Map.put(options, :password, input.password), else: options

              if now() < deadline,
                do: PortSession.extract(broker, bytes, options, max(1, deadline - now())),
                else: {:error, :timeout}
            catch
              :exit, _ -> {:error, :unknown_outcome}
            end

          case ResourceRegistry.release(binding.resource_registry, handle, binding.owner_id) do
            {:ok, _} -> result
            _ -> {:error, :unknown_outcome}
          end

        error ->
          case cleanup(supervisor, broker) do
            :ok -> error
            _ -> {:error, :unknown_outcome}
          end
      end
    else
      false -> failure(:timeout, "PDF invocation timed out")
      _ -> failure(:execution_failure, "PDF extractor is unavailable")
    end
  end

  defp cleanup(supervisor, broker) do
    with {:ok, %{cleanup_confirmed: true}} <- PortSession.close(broker),
         :ok <- DynamicSupervisor.terminate_child(supervisor, broker) do
      :ok
    else
      _ -> {:uncertain, :pdf_cleanup_unconfirmed}
    end
  catch
    :exit, _ -> {:uncertain, :pdf_cleanup_unconfirmed}
  end

  defp analyze([], _documents, _input, _config, _binding, _deadline, _extractions, _attempts),
    do: failure(:execution_failure, "Configured PDF analysis models did not complete")

  defp analyze(
         [candidate | rest],
         documents,
         input,
         config,
         binding,
         deadline,
         extractions,
         attempts
       ) do
    case candidate_parts(candidate, documents, input, config, binding, deadline, extractions) do
      {:ok, parts, notices, extractions} ->
        case Analysis.run(candidate, parts, deadline) do
          {:ok, text} ->
            {:ok, text, candidate.reference, candidate.native, notices,
             attempts ++ [%{model: candidate.reference, status: "completed"}]}

          {:error, {:terminal, _}} ->
            analyze(
              rest,
              documents,
              input,
              config,
              binding,
              deadline,
              extractions,
              attempts ++ [%{model: candidate.reference, status: "unavailable"}]
            )

          {:error, :unknown_outcome} ->
            {:error, :unknown_outcome}

          _ ->
            failure(:execution_failure, "PDF model analysis did not complete")
        end

      {:content_unavailable, extractions} ->
        analyze(
          rest,
          documents,
          input,
          config,
          binding,
          deadline,
          extractions,
          attempts ++ [%{model: candidate.reference, status: "content_unavailable"}]
        )

      error ->
        error
    end
  end

  defp candidate_parts(
         %{native: true},
         documents,
         input,
         _config,
         _binding,
         _deadline,
         extractions
       ) do
    case Context.native_parts(documents, input) do
      {:ok, parts} -> {:ok, parts, [], extractions}
      {:error, _} -> {:content_unavailable, extractions}
    end
  end

  defp candidate_parts(candidate, documents, input, config, binding, deadline, nil) do
    with {:ok, extractions} <- extract(documents, input, config, binding, deadline),
         do: candidate_parts(candidate, documents, input, config, binding, deadline, extractions)
  end

  defp candidate_parts(candidate, _documents, input, _config, _binding, _deadline, extractions) do
    case Context.parts(extractions, input, candidate.supports_images) do
      {:ok, parts, notices} -> {:ok, parts, notices, extractions}
      {:error, _} -> {:content_unavailable, extractions}
    end
  end

  defp output(text, model, native, notices, documents, attempts) do
    content = Enum.join([text | notices], "\n\n")

    result = %{
      content: content,
      model: model,
      native: native,
      provenance: Enum.map(documents, &Map.take(&1, [:resolved_input, :rewritten_from])),
      attempts: attempts
    }

    case ToolEffects.validate_output(%{payload: result}) do
      {:ok, _} -> {:ok, result}
      _ -> failure(:budget_exceeded, "PDF analysis result exceeds the native result budget")
    end
  end

  defp descriptor(context) do
    %{
      tool_name: @name,
      tool_revision: 1,
      description:
        "Analyze up to 10 PDFs using configured or automatically resolved analysis models. Eligible Anthropic/Google models receive complete native PDFs; other models use bounded text/image extraction. pages and password are non-native only.",
      schema: schema(),
      safety: %{read_only: true, retry_safe: false, parallel_safe: false},
      codex_exposure: :direct_model_only,
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{"type" => "string"},
        "pdf" => %{"type" => "string", "description" => "One PDF path/URL."},
        "pdfs" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "PDF paths/URLs; max 10."
        },
        "pages" => %{
          "type" => "string",
          "description" => "Pages, e.g. 1-5 or 1,3,5-7; up to the configured page limit."
        },
        "password" => %{"type" => "string", "description" => "Password for encrypted PDFs."},
        "model" => %{"type" => "string"},
        "maxBytesMb" => %{"type" => "number", "exclusiveMinimum" => 0}
      },
      "additionalProperties" => false
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
