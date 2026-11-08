defmodule Synapsis.Agent.Tools.Diffs do
  @moduledoc """
  Selected native Diffs rendering with expiring viewer and file receipts.

  One registered renderer belongs to one native invocation. Both mode publishes
  its viewer before file reservation/export, sharing the immutable request and
  deadline. Only small text receipts enter model history; published bytes and
  cleanup live behind the data/Workspace delivery boundary.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.Agent.DiffsDelivery
  alias Synapsis.Agent.Tools.CatalogBinding
  alias Synapsis.Diffs.{Config, PortSession, Request}
  alias Synapsis.Session.InputContext
  alias Synapsis.{AgentConfig, AgentConfigs}

  @name "synapsis::diffs"
  @keys ~w(identity agent_id agent_name fingerprint config source_context host_origin session_binding)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @close_reserve 12_000
  @publication_reserve 5_000
  @max_bytes 32 * 1024 * 1024

  def names, do: [@name]
  def permission_level(@name), do: :execute

  def bundles(context, identity, authority, selection, binding) do
    if @name in selection do
      with true <- @name in authority.grants,
           {:ok, agent, config, origin} <- configuration(context.agent[:name]),
           trusted = %{
             identity: identity,
             agent_id: agent.id,
             agent_name: agent.name,
             fingerprint: fingerprint(agent, config, origin),
             config: config,
             host_origin: origin,
             source_context: source_context(context, agent.id, identity.session_id),
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
        false -> failure(:forbidden, "Diffs exceeds the parent authority ceiling")
        {:error, %Error{}} = error -> error
        _ -> unavailable()
      end
    else
      {:ok, []}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, plan} <- invocation(context, operation) do
      {:ok,
       %{
         action: "diffs.render",
         resource: "diffs:" <> digest({context.agent_id, context.fingerprint, plan}),
         permission_level: :execute
       }}
    else
      false -> failure(:forbidden, "Diffs invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "Diffs descriptor is unavailable")

  def tool_effect_timeout(%{tool_name: @name, tool_revision: 1}, %{
        catalog_snapshot: %{registry: registry}
      }) do
    case ToolRegistry.lookup(registry, @name) do
      {:ok, %{backend: __MODULE__, backend_context: %{config: config}}} ->
        {:ok, config["host"]["timeoutMs"] + @publication_reserve + @close_reserve}

      _ ->
        failure(:validation, "Diffs timing descriptor is unavailable")
    end
  end

  def tool_effect_timeout(%{tool_name: @name}, _),
    do: failure(:validation, "Diffs timing descriptor is unavailable")

  def tool_effect_timeout(_, _), do: :default

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    context = Map.take(enriched, @keys)

    with {:ok, plan} <- invocation(context, operation) do
      case plan do
        %{"details" => %{"changed" => false}} -> output(plan)
        _ -> render(operation, context, plan)
      end
    else
      {:error, %Error{} = error} -> ToolEffects.reject(operation, error)
      _ -> failure(:validation, "Diffs invocation is unavailable")
    end
  rescue
    _ -> failure(:unknown_outcome, "Diffs work could not be observed; it was not replayed")
  catch
    :exit, _ -> failure(:unknown_outcome, "Diffs work could not be observed; it was not replayed")
  end

  def execute(_), do: failure(:validation, "Diffs context is unavailable")

  @impl true
  def cancel(_operation), do: :ok

  defp invocation(context, operation) do
    with true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- operation[:tool_name] === @name,
         :ok <-
           CatalogBinding.host(context, operation, __MODULE__, 1, @native_keys, context.identity),
         {:ok, _} <- Session.validate(context.session_binding, operation),
         {:ok, agent, config, origin} <- configuration(context.agent_name),
         true <- agent.id === context.agent_id,
         true <- fingerprint(agent, config, origin) === context.fingerprint,
         {:ok, arguments} <- InputSchema.validate(schema(), operation.arguments),
         {:ok, plan} <-
           Request.prepare(arguments, %{
             "defaults" => context.config["defaults"],
             "context" => context.source_context,
             "languagePackAvailable" => false
           }),
         :ok <- supported_plan(plan) do
      {:ok, plan}
    else
      false -> failure(:forbidden, "Diffs configuration changed; prepare a new run")
      {:error, %Error{}} = error -> error
      _ -> failure(:validation, "Diffs input or binding is unavailable")
    end
  end

  # The original patch-only parser has no oldFile/newFile arguments, so every
  # parsed patch is partial. Pierre 1.5.2 needs the omitted loadDiffFiles callback
  # for expansion. Keep this combination stopped before publishing a ready URL.
  # Original failure: /tmp/synapsis-diffs352-evidence/upstream-report.md.
  defp supported_plan(%{
         "input" => %{"kind" => "patch"},
         "options" => %{"expandUnchanged" => true}
       }),
       do:
         failure(
           :unsupported_capability,
           "Partial patch expansion awaits the upstream Diffs viewer fix"
         )

  defp supported_plan(_), do: :ok

  defp configuration(name) do
    with %AgentConfig{enabled: true} = agent <- AgentConfigs.get_by_name(name),
         {:ok, config} <- Config.load(),
         host =
           Map.put_new(
             config["host"],
             "helperPath",
             Application.app_dir(:synapsis_core, "priv/diffs_renderer/stdio.mjs")
           ),
         true <-
           Enum.all?(~w(nodeExecutable chromiumExecutable helperPath), &absolute_file?(host[&1])) do
      {:ok, agent, Map.put(config, "host", host),
       Application.get_env(:synapsis_agent, :diffs_host_origin)}
    else
      _ -> unavailable()
    end
  end

  defp source_context(context, agent_id, session_id) do
    base = %{"agentId" => agent_id, "sessionId" => session_id}
    ingress = context[:input_context]

    if InputContext.validate(ingress, session_id) == :ok and ingress["kind"] != "operator" do
      Map.merge(base, %{
        "messageChannel" => ingress["provider"],
        "agentAccountId" => ingress["account_id"]
      })
    else
      base
    end
  end

  defp render(operation, context, plan) do
    host = context.config["host"]
    deadline = now() + host["timeoutMs"] + @publication_reserve + @close_reserve

    with {:ok, deadline} <- native_deadline(operation, deadline),
         staging = Path.join(host["artifactRoot"] <> ".staging", Ecto.UUID.generate()),
         :ok <- staging_directory(staging),
         {:ok, supervisor} <-
           ResourceRegistry.worker_supervisor(context.session_binding.resource_registry),
         {:ok, broker} <-
           DynamicSupervisor.start_child(
             supervisor,
             {PortSession,
              owner_pid: context.session_binding.owner_pid,
              node_executable: host["nodeExecutable"],
              chromium_executable: host["chromiumExecutable"],
              helper_path: host["helperPath"],
              staging_root: staging}
           ) do
      registered_render(operation, context, plan, deadline, staging, supervisor, broker)
    else
      {:error, %Error{}} = error -> error
      _ -> failure(:execution_failure, "Diffs renderer is unavailable")
    end
  end

  defp registered_render(operation, context, plan, deadline, staging, supervisor, broker) do
    binding = context.session_binding
    cleanup = fn -> cleanup(supervisor, broker, staging) end

    case ResourceRegistry.register(binding.resource_registry, binding.owner_id, :diffs, broker,
           incarnation: binding.incarnation,
           owner_pid: binding.owner_pid,
           cleanup: cleanup
         ) do
      {:ok, handle} ->
        delivery_binding = %{
          session_id: context.identity.session_id,
          agent_id: context.agent_id,
          invocation: Map.take(operation, ~w(run_id invocation_id tool_call_id tool_name)a)
        }

        opts = [
          root: context.config["host"]["artifactRoot"],
          staging_root: staging,
          max_bytes: @max_bytes,
          deadline: deadline - @close_reserve
        ]

        result =
          try do
            render_phases(broker, plan, delivery_binding, opts, context, operation.arguments)
          rescue
            _ -> failure(:unknown_outcome, "Diffs rendering could not be observed")
          catch
            :exit, _ -> failure(:unknown_outcome, "Diffs rendering could not be observed")
          end

        case ResourceRegistry.release(binding.resource_registry, handle, binding.owner_id) do
          {:ok, _} -> result
          _ -> failure(:unknown_outcome, "Diffs renderer cleanup could not be confirmed")
        end

      _ ->
        case cleanup.() do
          :ok -> failure(:execution_failure, "Diffs renderer registration is unavailable")
          _ -> failure(:unknown_outcome, "Diffs renderer cleanup could not be confirmed")
        end
    end
  end

  defp render_phases(broker, plan, binding, opts, context, arguments) do
    if plan["mode"] in ~w(view both) do
      with {:ok, rendered} <- phase(broker, plan, "viewer", opts),
           {:ok, viewer} <- DiffsDelivery.publish_viewer(rendered, plan, binding, opts),
           {:ok, url} <-
             DiffsDelivery.viewer_url(viewer, %{
               base_url: arguments["baseUrl"],
               viewer_base_url: context.config["viewerBaseUrl"],
               host_origin: context.host_origin
             }) do
        details = viewer_details(viewer, rendered, plan, url)

        if plan["mode"] == "view" do
          output(%{
            "content" => [%{"type" => "text", "text" => "Diff viewer ready.\n" <> url}],
            "details" => details
          })
        else
          case render_file(broker, plan, binding, opts) do
            {:ok, file, _} ->
              file_result(file, rendered, plan, details, url)

            {:error, %Error{class: :unknown_outcome}} = error ->
              error

            {:error, reason} when reason in [:unknown_outcome, :delivery_uncertain, :timeout] ->
              render_error({:error, :unknown_outcome})

            {:error, _} ->
              message = "Diff file export did not complete"

              output(%{
                "content" => [
                  %{
                    "type" => "text",
                    "text" => "Diff viewer ready.\n#{url}\nFile rendering failed: #{message}"
                  }
                ],
                "details" => Map.put(details, "fileError", message)
              })
          end
        end
      else
        error -> render_error(error)
      end
    else
      case render_file(broker, plan, binding, opts) do
        {:ok, file, rendered} -> file_result(file, rendered, plan, nil, nil)
        error -> render_error(error)
      end
    end
  end

  defp render_file(broker, plan, binding, opts) do
    with {:ok, reservation} <- DiffsDelivery.reserve_file(plan, binding, opts),
         {:ok, rendered} <- phase(broker, plan, "image", opts),
         {:ok, file} <-
           DiffsDelivery.complete_file(reservation, rendered["artifacts"]["file"], opts) do
      {:ok, file, rendered}
    end
  end

  defp phase(broker, plan, target, opts) do
    remaining = opts[:deadline] - now()

    if remaining > 0,
      do:
        PortSession.render(broker, Map.put(plan, "renderTarget", target), min(120_000, remaining)),
      else: {:error, :timeout}
  end

  defp viewer_details(viewer, rendered, plan, url) do
    common_details(rendered, plan, viewer.record.public_id, viewer.expires_at)
    |> Map.merge(%{"viewerUrl" => url, "viewerPath" => viewer.viewer_path})
  end

  defp common_details(rendered, plan, id, expires_at) do
    %{
      "changed" => true,
      "artifactId" => id,
      "title" => rendered["title"],
      "expiresAt" => expires_at,
      "inputKind" => rendered["inputKind"],
      "fileCount" => rendered["fileCount"],
      "mode" => plan["mode"]
    }
    |> then(fn details ->
      if plan["context"], do: Map.put(details, "context", plan["context"]), else: details
    end)
  end

  defp file_result(file, rendered, plan, viewer_details, viewer_url) do
    image = plan["options"]["image"]

    details =
      (viewer_details || common_details(rendered, plan, file.record.public_id, file.expires_at))
      |> Map.merge(%{
        "filePath" => file.file_path,
        "path" => file.file_path,
        "fileBytes" => file.descriptor["bytes"],
        "fileFormat" => image["format"],
        "fileQuality" => image["qualityPreset"],
        "fileScale" => image["scale"],
        "fileMaxWidth" => image["maxWidth"],
        "fileDelivery" => file.reference,
        "fileExpiresAt" => file.expires_at
      })

    text =
      if(viewer_url, do: ["Diff viewer: " <> viewer_url], else: []) ++
        [
          "Diff #{String.upcase(image["format"])} generated at: #{file.file_path}",
          "To send this file, use an available file-sending tool to send it as an attachment."
        ]

    output(%{
      "content" => [%{"type" => "text", "text" => Enum.join(text, "\n")}],
      "details" => details
    })
  end

  defp output(result) do
    native = %{content: result["content"], details: result["details"]}

    case ToolEffects.validate_output(%{payload: native}) do
      {:ok, _} -> {:ok, native}
      _ -> failure(:budget_exceeded, "Diffs receipt exceeds the native result budget")
    end
  end

  defp native_deadline(operation, configured) do
    case operation.backend_context[:effect_deadline] do
      accessor when is_function(accessor, 0) ->
        case accessor.() do
          {:ok, %{remaining_ms: remaining}} when is_integer(remaining) and remaining > 0 ->
            {:ok, min(configured, now() + remaining)}

          _ ->
            failure(:resource_conflict, "Diffs effect is no longer live")
        end

      _ ->
        failure(:validation, "Diffs effect deadline is unavailable")
    end
  end

  defp cleanup(supervisor, broker, staging) do
    with {:ok, %{cleanup_confirmed: true}} <- PortSession.close(broker),
         :ok <- DynamicSupervisor.terminate_child(supervisor, broker),
         {:ok, _} <- File.rm_rf(staging) do
      :ok
    else
      _ -> {:uncertain, :diffs_cleanup_unconfirmed}
    end
  catch
    :exit, _ -> {:uncertain, :diffs_cleanup_unconfirmed}
  end

  defp staging_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        with :ok <- staging_directory(Path.dirname(path)), do: File.mkdir(path)

      _ ->
        {:error, :invalid_staging_path}
    end
  end

  defp render_error({:error, %Error{}} = error), do: error

  defp render_error({:error, :unknown_outcome}),
    do: failure(:unknown_outcome, "Diffs rendering could not be confirmed")

  defp render_error({:error, reason}) when reason in [:delivery_uncertain, :timeout],
    do: failure(:unknown_outcome, "Diffs delivery could not be confirmed")

  defp render_error(_), do: failure(:execution_failure, "Diffs rendering is unavailable")

  defp absolute_file?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.regular?(path)

  defp fingerprint(agent, config, origin),
    do: digest({agent.id, agent.name, agent.tools, config, origin})

  defp digest(value),
    do:
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic])),
        case: :lower
      )

  defp now, do: System.monotonic_time(:millisecond)

  defp unavailable,
    do:
      failure(
        :unsupported_capability,
        "Diffs requires an enabled Agent and explicit trusted Node/Chromium configuration"
      )

  defp failure(class, message), do: {:error, Error.new(class, message)}

  defp descriptor(context) do
    %{
      tool_name: @name,
      tool_revision: 1,
      description:
        "Create a read-only diff viewer from before/after text or a unified patch. Returns a viewer URL for interactive viewing and can also render the same diff to a PNG or PDF. Compared files are never edited.",
      schema: schema(),
      safety: %{read_only: false, retry_safe: false, parallel_safe: false},
      codex_exposure: :direct_model_only,
      backend: __MODULE__,
      backend_context: context
    }
  end

  defp schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "before" => %{"type" => "string", "description" => "Original text content."},
        "after" => %{"type" => "string", "description" => "Updated text content."},
        "patch" => %{
          "type" => "string",
          "maxLength" => 2 * 1024 * 1024,
          "description" => "Unified diff or patch text."
        },
        "path" => %{
          "type" => "string",
          "maxLength" => 2048,
          "description" => "Display path for before/after input."
        },
        "lang" => %{
          "type" => "string",
          "maxLength" => 128,
          "description" => "Optional language override for before/after input."
        },
        "title" => %{
          "type" => "string",
          "maxLength" => 1024,
          "description" => "Optional title for the rendered diff."
        },
        "mode" => %{
          "type" => "string",
          "enum" => ~w(view image file both),
          "description" =>
            "Output mode: view, file, image (deprecated alias for file), or both. Default: both."
        },
        "theme" => %{
          "type" => "string",
          "enum" => ~w(light dark),
          "description" => "Viewer theme. Default: dark."
        },
        "layout" => %{
          "type" => "string",
          "enum" => ~w(unified split),
          "description" => "Diff layout. Default: unified."
        },
        "fileQuality" => %{
          "type" => "string",
          "enum" => ~w(standard hq print),
          "description" => "File quality preset: standard, hq, or print."
        },
        "fileFormat" => %{
          "type" => "string",
          "enum" => ~w(png pdf),
          "description" => "Rendered file format: png or pdf."
        },
        "fileScale" => %{
          "type" => "number",
          "minimum" => 1,
          "maximum" => 4,
          "description" => "Optional rendered-file device scale factor override (1-4)."
        },
        "fileMaxWidth" => %{
          "type" => "number",
          "minimum" => 640,
          "maximum" => 2400,
          "description" => "Optional rendered-file max width in CSS pixels (640-2400)."
        },
        "expandUnchanged" => %{
          "type" => "boolean",
          "description" => "Expand unchanged sections instead of collapsing them."
        },
        "ttlSeconds" => %{
          "type" => "number",
          "minimum" => 1,
          "maximum" => 21600,
          "description" => "Artifact lifetime in seconds. Default: 1800. Maximum: 21600."
        },
        "baseUrl" => %{
          "type" => "string",
          "description" =>
            "Optional gateway base URL override used when building the viewer URL. Overrides configured viewerBaseUrl."
        }
      }
    }
  end
end
