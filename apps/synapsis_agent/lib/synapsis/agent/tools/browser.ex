defmodule Synapsis.Agent.Tools.Browser do
  @moduledoc """
  Selected native Browser, bound to trusted managed-host or remote-CDP profiles.

  Only process-local native Session resources survive successful turn detach.
  Configuration replacement requires confirmed cleanup; durable history never
  restores a browser or replays an action. Managed profiles own their Chromium;
  remote profiles own only their connection. Driver capabilities and partial
  snapshot/options support remain explicit, not full Browser parity.
  """
  @behaviour Backplane.AgentRuntime.ToolEffects

  alias Backplane.AiProtocol.Validation
  alias Backplane.AgentRuntime.{Error, InputSchema, ToolCatalog, ToolEffects, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Synapsis.{AgentConfig, AgentConfigs}
  alias Synapsis.Browser.{PortSession, Timing}
  alias Synapsis.Filesystem.Local

  @name "synapsis::browser"
  @actions ~w(status start stop profiles tabs open focus close navigate snapshot act screenshot doctor console requests errors text emulate dialog pdf download waitfordownload upload)
  @read_actions ~w(status profiles tabs snapshot screenshot doctor console requests errors text)
  @context_keys ~w(identity agent_id agent_name config project_root fingerprint session_binding record)a
  @native_keys ~w(interact effect_deadline append_feedback emit catalog_snapshot stage_catalog
    request_new_context nested_dispatch register_cancellation register_code_mode cancellation_coordinator resource_owner_pid goal goal_binding)a
  @cache_limit 64

  def names, do: [@name]
  def permission_level(@name), do: :execute

  def tool_effect_timeout(%{tool_name: @name, tool_revision: revision} = invocation, %{
        catalog_snapshot: %{registry: registry}
      }) do
    with {:ok,
          %{backend: __MODULE__, tool_revision: ^revision, backend_context: %{config: config}}} <-
           ToolRegistry.lookup(registry, @name),
         true <- revision == 1,
         {:ok, plan} <- Timing.plan(config, invocation.arguments) do
      {:ok, plan.native_timeout_ms}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> failure(:validation, "Browser timing descriptor is unavailable")
    end
  end

  def tool_effect_timeout(%{tool_name: @name}, _),
    do: failure(:validation, "Browser timing descriptor is unavailable")

  def tool_effect_timeout(_, _), do: :default

  def bundles(context, identity, ceiling, selection, binding, cache) do
    cache = prune(cache)

    if @name in selection do
      with true <- @name in ceiling.grants,
           {:ok, agent, config} <- configuration(context.agent[:name]),
           {:ok, project_root} <- project_root(context),
           fingerprint = fingerprint(agent, config, project_root),
           {:ok, record} <- resource_record(binding, config, project_root, fingerprint, cache),
           trusted = %{
             identity: identity,
             agent_id: agent.id,
             agent_name: agent.name,
             config: config,
             project_root: project_root,
             fingerprint: fingerprint,
             session_binding: binding,
             record: record
           },
           authority = %{
             ceiling
             | grants: [@name],
               tool_revisions: Map.take(ceiling.tool_revisions, [@name])
           },
           {:ok, bundle} <-
             ToolCatalog.admit_batch([descriptor(trusted)], authority: authority, mode: :strict) do
        {:ok, [bundle], Map.put(cache, owner_key(binding), record)}
      else
        false -> failure(:forbidden, "Browser exceeds the parent authority ceiling")
        error -> error
      end
    else
      {:ok, [], cache}
    end
  end

  def classify(%{backend: __MODULE__, backend_context: context}, identity, operation) do
    with true <- context.identity === identity,
         {:ok, arguments, _pid} <- invocation(context, operation) do
      action = arguments["action"]
      profile = Map.get(arguments, "profile", context.config["default_profile"])

      {:ok,
       %{
         action: "browser." <> action,
         resource:
           "browser:" <>
             Jason.encode!([
               context.agent_id,
               context.agent_name,
               profile,
               action,
               arguments_digest(arguments)
             ]),
         permission_level:
           if(
             action in @read_actions and get_in(arguments, ["args", "clear"]) !== true and
               action != "screenshot" and
               not (action == "snapshot" and get_in(arguments, ["args", "labels"]) === true),
             do: :read,
             else: :execute
           )
       }}
    else
      false -> failure(:forbidden, "Browser invocation scope changed")
      error -> error
    end
  end

  def classify(_, _, _), do: failure(:validation, "Browser descriptor is unavailable")

  @impl true
  def execute(%{backend_context: enriched} = operation) do
    context = Map.take(enriched, @context_keys)

    case invocation(context, operation) do
      {:ok, arguments, pid} ->
        dispatch(operation, context, arguments, pid, enriched[:effect_deadline])

      {:error, %Error{} = error} ->
        ToolEffects.reject(operation, error)
    end
  rescue
    _ -> failure(:unknown_outcome, "Browser execution could not be observed")
  catch
    :exit, _ -> failure(:unknown_outcome, "Browser execution transport is unavailable")
  end

  def execute(_), do: failure(:validation, "Browser context is unavailable")

  @impl true
  def cancel(%{backend_context: enriched} = operation) do
    context = Map.take(enriched, @context_keys)

    # Cancellation uses only this invocation's exact registered brokers. Config
    # rotation cannot redirect cancellation to a newly selected process.
    with :ok <- scope(context, operation),
         {:ok, _owner} <- Session.validate(context.session_binding, operation),
         {:ok, arguments} <- InputSchema.validate(schema(), operation.arguments) do
      profiles =
        if arguments["action"] == "profiles",
          do: Map.keys(context.record.profiles),
          else: [Map.get(arguments, "profile", context.config["default_profile"])]

      Enum.reduce_while(profiles, :ok, fn profile, :ok ->
        with {:ok, pid} <- broker(context, profile),
             {:ok, _receipt} <- PortSession.cancel(pid) do
          {:cont, :ok}
        else
          _ -> {:halt, failure(:unknown_outcome, "Browser cancellation is unconfirmed")}
        end
      end)
    end
  rescue
    _ -> failure(:unknown_outcome, "Browser cancellation is unconfirmed")
  catch
    :exit, _ -> failure(:unknown_outcome, "Browser cancellation is unconfirmed")
  end

  def cancel(_), do: failure(:validation, "Browser context is unavailable")

  defp descriptor(context) do
    %{
      tool_name: @name,
      tool_revision: 1,
      description:
        "Control a configured managed-host or remote-CDP browser. Call start explicitly before browsing. " <>
          "Supported actions: status, start, stop, profiles (all configured profiles), doctor, tabs, open, focus, close, navigate, snapshot, screenshot, act, console, requests, errors, text, emulate, dialog, pdf, download, waitfordownload, upload. " <>
          "Select only a configured profile; launch settings come from trusted Agent configuration. " <>
          "Remote-CDP stop disconnects without closing the external browser or its tabs. " <>
          "Remote-CDP supports PDF and byte uploads; download/waitfordownload require managed-host. " <>
          "Screenshots and labeled AI snapshots save unique project-local image files and include their paths; image mode also returns inline pixels. " <>
          "AI snapshots default to page-wide public Playwright ARIA refs. Explicit shaping/scope options select native Chromium AX role refs unless refs=aria; refs=role alone keeps the page-wide default. Raw ARIA snapshots return main-document AX nodes with distinct actionable Element refs; full Browser snapshot parity is not claimed. " <>
          "navigate and batch act results that report navigation include a compact pageState snapshot when available; use its refs directly without a separate snapshot call. Managed navigate to an attachment instead saves a unique project-local file and returns download {url,suggestedFilename,path,bytes,sha256} with the actual download URL; it has no pageState and retains the unchanged original page refs. Remote-CDP downloads remain unavailable. After a single act that triggers navigation, snapshot before using refs. " <>
          "Existing-session, sandbox/node routes and remaining Browser actions are not implemented.",
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
      "properties" => %{
        "action" => %{"type" => "string", "enum" => @actions},
        "args" => %{
          "type" => "object",
          "default" => %{},
          "additionalProperties" => true,
          "description" =>
            "Action parameters. open/navigate: targetUrl (or url). open also accepts label: trim whitespace, then 1..64 ASCII letters, numbers, _, ., :, or -. Reusing a case-sensitive label moves it to the newly opened tab; the older tab keeps its stable ID. open/tabs/status tab entries return the actual CDP targetId, a separate profile-owned tN tabId, suggestedTargetId (label or tabId) and optional label. Tab actions trim and resolve exact raw IDs, tN aliases or case-sensitive labels; when there is no exact match, a unique case-insensitive raw CDP ID prefix is accepted. Omit targetId to reuse the last selected page; selecting a page for reading does not foreground it. tabs/status preserve selection. Closing another page preserves selection; explicitly closing the selected page clears it so the next targetless action chooses the first live page. A confidently matched page replacement retains its friendly tabId, label and selection while exposing its new raw targetId; snapshot refs and page state start fresh. Matching uses one stale/one new page, otherwise unique matching URL pairs from the complete live list. Explicit close retires the alias; explicit open claims a fresh one. Normal stop/start in the same profile host preserves aliases, labels and selection for surviving or confidently replaced targets; Page handles, refs, snapshot baselines and observation histories start fresh. Final host close releases this metadata; completed-history replay does not restore a browser. Numeric-index lookup is unavailable. " <>
              "snapshot: snapshotFormat=ai defaults to page-wide AI ARIA capture, including when refs=role is supplied alone or labels/urls/interactive/compact are false. labels=true, urls=true, mode=efficient, interactive=true, compact=true, explicit depth or selector/frame select native AX role capture unless refs=aria is explicit; selector CSS defaults to :root, frame CSS selects an iframe without child-frame recursion. Native role duplicates use source AX-array occurrence order before shaping and add [nth=N] for later occurrences; exact Element handles remain the action target. A genuinely empty scoped role snapshot returns (empty), or (no interactive elements) in interactive mode. These markers consume the existing output budget; budget-truncated content can still be empty. AI refs=aria captures page-wide public Playwright YAML including shadow/iframe controls, preserves YAML text/states/property layout with pinned rendered-line shaping, and does not support selector/frame. Playwright omits accessible names longer than 900 UTF-16 units from YAML and public ref metadata; the exact Element handle remains actionable. Host-monotonic e aliases retain exact Element handles from public Playwright source refs, including frame refs. limit defaults 100/max 500; depth defaults/max 100; maxChars defaults 40000/max 131072, with a separate 262144 UTF-8 byte budget. interactive and compact are booleans; mode=efficient defaults interactive=true, compact=true, depth=6, maxChars=8000; explicit false/0 overrides defaults. snapshotFormat=aria uses main-document native Chromium AX preorder, including ignored/document/text/virtual nodes. Its ax aliases are informational unless actionable=true; refs/refCount include only exactly bound DOM Elements, nodeCount includes all nodes. Raw limit defaults 500/max 2000; valid refs/depth/interactive/compact/maxChars are ignored, selector/frame and mode=efficient are unsupported. Raw output truncates only whole nodes at the UTF-8 budget; valid urls is also ignored. AI urls=true appends up to 100 unique absolute document anchor URLs with normalized labels of at most 120 UTF-16 units; role uses the selected frame document even with a smaller selector, AI aria uses the main document. It does not collect shadow or child-frame anchors. The appendix shares maxChars/UTF-8 budgets and keeps whole entries; omitted entries set truncated. urls=false or absent adds no appendix. AI snapshot delta is automatic: repeated same-document/options captures report newElements (including 0), mark new exported ref lines [new], and append a whole-line summary when it fits. The first comparable capture omits newElements; role identity uses role/name/occurrence, AI aria uses the original Playwright ref before host aliases. Reload and frame-document changes reset the relevant baseline; hash navigation retains it. Baselines are process-local, at most 32 families including the local body line limit, and clear on tab close/host stop. Raw AX does not participate. There is no delta input argument. AI labels=true returns the same finalized snapshot refs and metadata with an annotated viewport image in ordered text/image content; selector/frame and shaping options stay in the snapshot, with no extra role refresh. Label image cleanup and image budget checks complete before refs and the delta baseline are adopted. Labels share the ordinary snapshot delta family; labels=false or absent remains text-only. Raw snapshotFormat=aria does not support labels=true. The combined image uses the existing screenshot label limits and image-pixel annotations; screenshot type/fullPage/ref/element options do not crop or change snapshot images. Combined snapshot images remain inline under trusted screenshot path mode. Browser artifacts normalize to at most 2000px/5MiB before storage; inline images independently normalize to 1200px/5MiB. Conversion may change the requested PNG/JPEG format to JPEG. Artifact type/bytes/hash and annotations describe the saved image; inline MIME/data describe the separate model image. Existing configured image and native result budgets still apply. " <>
              "snapshot query: optional nonblank string; trim and match all whitespace-separated tokens case-insensitively against returned source lines in order. AI and raw ARIA queries return matching snapshot text, summary, matchCount before the query cap and current stats; only matching refs and raw nodes appear publicly. refs/refCount remain actionable; raw stats.refs also counts matching informational AX nodes. Raw capture ignores maxChars, but query text independently uses positive maxChars or defaults to 40000, with the host's existing UTF-8/native JSON budgets; no reference text envelope is added. Queries retain the full private capture handles and delta baseline; labels and image annotations still describe the full source capture. newElements counts surviving marked lines. Blank query keeps the ordinary result. " <>
              "screenshot: type=png|jpeg, fullPage or ref/element CSS target (ref wins). labels=true draws up to 150 ref overlays and returns labelsCount, labelsSkipped and image-pixel annotations. Without ref it refreshes a bounded native role snapshot; an explicit ref uses the retained snapshot. Viewport-offscreen refs remain in annotations and count as skipped; element captures include only overlapping refs. Labels are removed before success; labels=false or absent captures ordinary pixels. Trusted Agent screenshot_result_mode=path saves a unique project artifact and returns a small receipt without image data; image mode is the default. The model cannot choose the mode or an output path. " <>
              "console: level, limit, clear; requests: URL substring filter, limit, clear; errors: limit, clear. Event histories are bounded per tab. " <>
              "text: optional selector and maxChars, returning visible innerText with truncation metadata. " <>
              "emulate: device (Playwright device name, emulated in owned Chromium), colorScheme=dark|light|no-preference|none, timezoneId, locale. " <>
              "dialog: accept boolean, optional promptText, dialogId and timeoutMs; respond to a pending dialog or arm the next one. " <>
              "pdf: optional path; saves a PDF with a path/bytes/sha256 receipt, without sending PDF content to the model. " <>
              "download: ref and path; waitfordownload: optional path, waits for the next download. " <>
              "File paths are relative to the trusted project root or absolute within it; omitted output paths create unique files in .synapsis/browser-files. Saved files survive Browser cleanup. " <>
              "upload: paths (1..32 files, at most 64 MiB total), optional inputRef or element for direct input assignment, ref for atomic chooser click; omit all three to arm the next chooser with a finite deadline. browserState.upload exposes completion and recent outcomes. " <>
              "If an act reports dialogPending, use browserState.dialogs.pending to respond before continuing. " <>
              "browserState.pendingActions lists interrupted actions with finite deadlines; actionPending means no new page work started because their capacity is full. Wait for settlement or close the browser. " <>
              "act: request object with kind. Managed standalone and nested batch actions capture downloads in event order and return an optional root downloads array with actual url, suggestedFilename, path, bytes and sha256; files use the existing unique project-local output paths and survive cleanup. A remote-CDP action that starts a download reports unsupported artifact transport without writing a local file. String refs for click/type/hover/scrollIntoView/evaluate and drag startRef/endRef are trimmed on private execution copies, including nested batches; raw ToolUse/history stays unchanged. click/hover/scrollIntoView: ref or selector; click also button/doubleClick/modifiers and delayMs (0..5000): hover first, delay, then click or real double-click. " <>
              "clickCoords: x,y,button,doubleClick,delayMs (0..5000 between mouse down/up). type: ref/selector,text,slowly,delayMs,submit; ordinary type replaces the value, slowly clicks then inserts at the resulting caret with 75ms per character by default; explicit delayMs (0..1000) is a host extension. press: key, optional ref/selector,delayMs (0..120000 between key down/up); aliases Esc,Return,Del,Ctrl,Cmd,space map to Escape,Enter,Delete,Control,Meta,Space; a literal space is Space, padded + remains +, and Ctrl+Space is a named chord. " <>
              "drag: startRef,endRef; uses retained snapshot handles, presses at the source before scrolling to and releasing at the destination, with pointer actionability and one shared timeout. select: ref/selector,values; string refs are trimmed on private execution copies, including nested batches; option strings retain exact content, including empty strings and surrounding whitespace. Ref targeting takes precedence over the selector extension; raw ToolUse/history stays unchanged. fill: fields[{ref/selector,type?,value?}], 1..100 fields. Ref strings and type labels are trimmed; blank/nonstring type defaults to text. Values accept string/number/boolean/null; missing/null clears text. Only explicit checkbox/radio types set checked, true only for true,1,\"1\",\"true\"; other types fill string values, so default-type booleans become text. Selector targeting is a host extension; select remains separate. Private field copies preserve raw ToolUse/history. " <>
              "resize: width,height. wait: timeMs,text,textGone,ref/selector,url,loadState,fn, checked sequentially in that order; selector uses the first match. String loadState/text/textGone/selector/url/fn values are trimmed and blanks omitted on private execution copies, including batch leaves; raw ToolUse/history stays unchanged. fn polls a synchronous or asynchronous page predicate until truthy, accepts a function, expression or statement body, and stays bound to the current document. The finite tool timeout covers the whole wait and batch. evaluate: fn function expression, optional ref. " <>
              "close: close selected tab. batch: nonempty actions, at most 100 recursive descendants including nested batch nodes, root batch depth 0 through 5; stopOnError applies at each level. " <>
              "Batch results retain nested results and action values; navigation/reload or tab close ends every enclosing batch, with aborted metadata only for remaining actions. Equivalent root and nested target aliases are resolved once before execution and must identify the selected tab. The finite tool timeout covers the entire batch. " <>
              "Refs expire after any frame navigation/detach, a new snapshot or document replacement; request a new snapshot. " <>
              "Do not supply executable, data_dir, node or other launch/routing configuration."
        },
        "profile" => %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 128,
          "description" =>
            "Configured managed-host or remote-CDP profile name; defaults to the configured default_profile."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 2_147_000_000,
          "description" =>
            "Outer watchdog in milliseconds. Overrides the automatic serial act budget; other actions use the selected trusted profile timeout. Profiles share one aggregate watchdog."
        }
      },
      "required" => ["action"],
      "additionalProperties" => false
    }
  end

  defp invocation(context, operation) do
    with :ok <- scope(context, operation),
         {:ok, agent, config} <- configuration(context.agent_name),
         true <-
           agent.id === context.agent_id and config === context.config and
             fingerprint(agent, config, context.project_root) === context.fingerprint,
         {:ok, _owner} <- Session.validate(context.session_binding, operation),
         {:ok, arguments} <- InputSchema.validate(schema(), operation.arguments),
         :ok <- action_arguments(arguments, config),
         {:ok, arguments} <- file_arguments(context, arguments),
         profile = Map.get(arguments, "profile", config["default_profile"]),
         {:ok, pid} <- broker(context, profile) do
      {:ok, arguments, pid}
    else
      false -> failure(:forbidden, "Browser configuration changed; prepare a new run")
      error -> error
    end
  end

  defp action_arguments(arguments, config) do
    args = Map.get(arguments, "args", %{})

    launch_fields =
      ~w(executable executablePath data_dir userDataDir node_executable helper_path
      profiles default_profile max_image_bytes screenshot_result_mode project_root launchOptions env headless driver endpoint cdpUrl)

    external_routes = ~w(node browser systemProfile into)
    profile = Map.get(arguments, "profile", config["default_profile"])

    cond do
      Enum.any?(launch_fields, &Map.has_key?(args, &1)) ->
        failure(
          :validation,
          "Browser launch configuration must come from trusted Agent configuration"
        )

      Enum.any?(external_routes, &Map.has_key?(args, &1)) or
          (Map.has_key?(args, "target") and args["target"] !== "host") ->
        failure(
          :unsupported_capability,
          "Only the configured host Browser route is implemented"
        )

      arguments["action"] == "profiles" and Map.has_key?(args, "profile") ->
        failure(:validation, "Browser profiles lists all configured profiles; omit args.profile")

      Map.has_key?(args, "profile") and args["profile"] !== profile ->
        failure(:validation, "Browser args.profile must match the selected configured profile")

      true ->
        :ok
    end
  end

  defp project_root(context) do
    with path when is_binary(path) <- context[:project_path],
         true <- absolute?(path),
         {:ok, root, _} <- Local.resolve(Path.expand(path), ".") do
      {:ok, root}
    else
      _ -> failure(:validation, "Browser requires a trusted project directory")
    end
  end

  defp file_arguments(context, %{"action" => action} = arguments)
       when action in ~w(pdf download waitfordownload upload) do
    args = Map.get(arguments, "args", %{})

    result =
      if action == "upload" do
        case args["paths"] do
          paths when is_list(paths) and length(paths) in 1..32 ->
            Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, resolved} ->
              case Local.resolve(context.project_root, path) do
                {:ok, absolute, _} -> {:cont, {:ok, [absolute | resolved]}}
                _ -> {:halt, :error}
              end
            end)
            |> case do
              {:ok, paths} -> {:ok, Map.put(args, "paths", Enum.reverse(paths))}
              _ -> :error
            end

          _ ->
            :error
        end
      else
        case Map.fetch(args, "path") do
          {:ok, path} ->
            case Local.resolve(context.project_root, path) do
              {:ok, absolute, _} -> {:ok, Map.put(args, "path", absolute)}
              _ -> :error
            end

          :error when action != "download" ->
            {:ok, args}

          :error ->
            :error
        end
      end

    case result do
      {:ok, args} -> {:ok, Map.put(arguments, "args", args)}
      _ -> failure(:validation, "Browser file arguments must resolve within the project")
    end
  end

  defp file_arguments(_context, arguments), do: {:ok, arguments}

  defp arguments_digest(arguments),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(arguments, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp scope(context, operation) do
    if Enum.sort(Map.keys(context)) == Enum.sort(@context_keys) and
         operation[:tool_name] === @name and operation[:tool_revision] === 1 do
      case operation[:backend_context] do
        %{catalog_snapshot: _} ->
          case Synapsis.Agent.Tools.CatalogBinding.host(
                 context,
                 operation,
                 __MODULE__,
                 1,
                 @native_keys,
                 context.identity
               ) do
            :ok -> :ok
            _ -> failure(:forbidden, "Browser invocation scope changed")
          end

        _ ->
          if Enum.all?([:run_id, :incarnation, :catalog_revision], fn key ->
               operation[key] === context.identity[key]
             end),
             do: :ok,
             else: failure(:forbidden, "Browser invocation scope changed")
      end
    else
      failure(:forbidden, "Browser invocation scope changed")
    end
  end

  defp broker(context, profile) do
    case context.record.profiles[profile] do
      %{handle: handle, pid: pid} ->
        with {:ok, ^pid} <-
               ResourceRegistry.fetch(
                 context.session_binding.resource_registry,
                 handle,
                 context.session_binding.owner_id
               ),
             true <- Process.alive?(pid) do
          {:ok, pid}
        else
          _ -> failure(:unknown_outcome, "Browser resource is unavailable")
        end

      _ ->
        failure(:validation, "Browser profile is not configured")
    end
  end

  defp dispatch(_operation, context, %{"action" => "profiles"} = arguments, _pid, deadline) do
    with {:ok, plan} <- Timing.plan(context.config, arguments) do
      context.record.profiles
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, [], plan.outer_timeout_ms}, fn {name, _},
                                                                {:ok, profiles, remaining} ->
        with {:ok, pid} <- broker(context, name),
             {:ok, _} <- PortSession.initialize(pid),
             {:ok, _after_initialize} <- remaining_timeout(deadline, remaining),
             {:ok, receipt, next_remaining} <-
               timed_call(pid, "profiles", %{}, remaining, deadline) do
          {:cont,
           {:ok,
            profiles ++
              Enum.map(receipt["profiles"], &Map.put(&1, "generation", receipt["generation"])),
            next_remaining}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, profiles, _remaining} -> output(%{"profiles" => profiles})
        error -> error
      end
    end
  end

  defp dispatch(operation, context, arguments, pid, deadline) do
    with {:ok, plan} <- Timing.plan(context.config, arguments),
         {:ok, _} <- PortSession.initialize(pid),
         {:ok, _after_initialize} <- remaining_timeout(deadline, plan.outer_timeout_ms) do
      case timed_call(
             pid,
             arguments["action"],
             Map.get(arguments, "args", %{}),
             plan.outer_timeout_ms,
             deadline
           ) do
        {:ok, result, _remaining} -> output(result)
        {:error, error} -> receipt_error(operation, error)
      end
    else
      {:error, error} -> receipt_error(operation, error)
    end
  end

  defp timed_call(pid, action, args, remaining, deadline) do
    with {:ok, timeout} <- remaining_timeout(deadline, remaining) do
      started = System.monotonic_time(:millisecond)

      case PortSession.call(pid, action, args, timeout) do
        {:ok, receipt} ->
          {:ok, receipt, max(0, remaining - (System.monotonic_time(:millisecond) - started))}

        error ->
          error
      end
    end
  end

  defp remaining_timeout(deadline, planned) when is_function(deadline, 0) do
    with {:ok, %{remaining_ms: remaining}} <- deadline.(),
         timeout when timeout > 0 <- min(planned, remaining - Timing.settlement_timeout_ms()) do
      {:ok, timeout}
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> failure(:timeout, "Browser effect has no active action allowance")
    end
  end

  defp remaining_timeout(_, _),
    do: failure(:resource_conflict, "Browser effect deadline is unavailable")

  defp receipt_error(_operation, %Error{} = error), do: {:error, error}

  defp receipt_error(operation, %{"dispatched" => false} = receipt) do
    ToolEffects.reject(operation, public_error(receipt))
  end

  defp receipt_error(_operation, _receipt),
    do: failure(:unknown_outcome, "Browser action outcome could not be confirmed")

  defp public_error(receipt) do
    {class, message} =
      case receipt["class"] do
        value
        when value in ~w(invalid_arguments invalid_request generation_conflict stale_reference stale_ref stale_snapshot) ->
          {:validation,
           "Browser arguments or references are invalid; refresh the snapshot when needed"}

        "not_implemented" ->
          {:unsupported_capability, "This Browser operation is not implemented"}

        "result_budget" ->
          {:budget_exceeded, "Browser result exceeds its configured budget"}

        "timeout" ->
          {:timeout, "Browser action timed out"}

        "cancelled" ->
          {:cancelled, "Browser action was cancelled"}

        _ ->
          {:execution_failure, "Browser operation is unavailable or failed before dispatch"}
      end

    Error.new(class, message, details: Map.take(receipt, ["class", "generation", "dispatched"]))
  end

  defp output(result) do
    public = Map.delete(result, "content")

    with :ok <- Validation.term(public),
         {:ok, content} <- output_content(result, public),
         native = public |> Map.put(:content, content) |> Map.put(:structured, public),
         :ok <-
           Validation.term(%{
             "version" => 1,
             "result" => Map.put(native, :is_error, false)
           }),
         {:ok, _} <- ToolEffects.validate_output(%{payload: native}) do
      {:ok, native}
    else
      _ ->
        # The helper already completed this action. Output omission is a settled
        # consumer error, never proof of non-dispatch or permission to retry it.
        {:ok,
         %{
           is_error: true,
           error:
             Error.new(
               :budget_exceeded,
               "Browser action completed but its result exceeds the native output budget; request a smaller result"
             )
         }}
    end
  end

  defp output_content(%{"content" => content}, _public), do: {:ok, content}
  defp output_content(_result, public), do: Jason.encode(public)

  defp resource_record(binding, config, project_root, fingerprint, cache) do
    case cache[owner_key(binding)] do
      %{fingerprint: ^fingerprint} = record ->
        with :ok <- fetch_record(binding, record), do: {:ok, %{record | binding: binding}}

      nil ->
        if map_size(cache) < @cache_limit,
          do: create_record(binding, config, project_root, fingerprint),
          else:
            failure(:overloaded, "Browser native owner cache is full; reconcile closed Sessions")

      old ->
        with :ok <- release_record(old),
             do: create_record(binding, config, project_root, fingerprint)
    end
  end

  defp fetch_record(binding, record) do
    Enum.reduce_while(record.profiles, :ok, fn {_name, %{handle: handle, pid: pid}}, :ok ->
      case ResourceRegistry.fetch(binding.resource_registry, handle, binding.owner_id) do
        {:ok, ^pid} -> {:cont, :ok}
        _ -> {:halt, failure(:unknown_outcome, "Browser resource requires confirmed cleanup")}
      end
    end)
  end

  defp create_record(binding, config, project_root, fingerprint) do
    with {:ok, supervisor} <- ResourceRegistry.worker_supervisor(binding.resource_registry) do
      result =
        config["profiles"]
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, %{}}, fn {name, profile}, {:ok, profiles} ->
          opts = [
            owner_pid: binding.owner_pid,
            node_executable: config["node_executable"],
            helper_path: config["helper_path"],
            config:
              profile
              |> Map.take(~w(driver executable data_dir endpoint timeout_ms max_image_bytes))
              |> Map.merge(
                if(config["screenshot_result_mode"] == "path",
                  do: %{"screenshot_result_mode" => "path"},
                  else: %{}
                )
              )
              |> Map.put("project_root", project_root)
              |> Map.put("profile", name)
          ]

          with {:ok, pid} <- DynamicSupervisor.start_child(supervisor, {PortSession, opts}) do
            case ResourceRegistry.register(
                   binding.resource_registry,
                   binding.owner_id,
                   :browser,
                   pid,
                   incarnation: binding.incarnation,
                   owner_pid: binding.owner_pid,
                   cleanup: fn -> cleanup(supervisor, pid) end
                 ) do
              {:ok, handle} ->
                {:cont, {:ok, Map.put(profiles, name, %{handle: handle, pid: pid})}}

              error ->
                # The broker is still dormant: no helper or Chromium has launched.
                cleanup(supervisor, pid)
                {:halt, error}
            end
          else
            _ -> {:halt, failure(:execution_failure, "Browser broker could not be started")}
          end
        end)

      case result do
        {:ok, profiles} ->
          {:ok, %{binding: binding, fingerprint: fingerprint, profiles: profiles}}

        error ->
          # Already registered resources remain native-Session-owned. The caller
          # closes failed preparation through public Session cleanup.
          error
      end
    end
  end

  defp cleanup(supervisor, pid) do
    with :ok <- PortSession.close(pid),
         :ok <- DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok
    else
      _ -> {:uncertain, :browser_cleanup_unconfirmed}
    end
  catch
    :exit, _ -> {:uncertain, :browser_cleanup_unconfirmed}
  end

  defp release_record(record) do
    binding = record.binding

    record.profiles
    |> Task.async_stream(
      fn {_name, %{handle: handle}} ->
        ResourceRegistry.release(binding.resource_registry, handle, binding.owner_id)
      end,
      max_concurrency: 8,
      timeout: 21_000,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
    |> Enum.all?(&match?({:ok, {:ok, _}}, &1))
    |> case do
      true ->
        :ok

      false ->
        failure(:unknown_outcome, "Browser configuration replacement cleanup is unconfirmed")
    end
  end

  defp prune(cache) do
    # This private cache is bounded. Dead owners without confirmed public cleanup
    # remain inspection records and cannot silently authorize replacement.
    Map.reject(cache, fn {_key, record} ->
      try do
        case Session.status(record.binding.session) do
          %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} -> true
          _ -> confirmed_dead_record?(record)
        end
      catch
        :exit, _ -> confirmed_dead_record?(record)
      end
    end)
  end

  defp confirmed_dead_record?(record) do
    binding = record.binding

    not Process.alive?(binding.owner_pid) and
      Enum.all?(record.profiles, fn {_name, %{handle: handle}} ->
        try do
          match?(
            {:ok, %{status: :confirmed}},
            ResourceRegistry.cleanup_status(binding.resource_registry, handle, binding.owner_id)
          )
        catch
          :exit, _ -> false
        end
      end)
  end

  defp owner_key(binding), do: {binding.owner_id, binding.incarnation}

  defp configuration(name) when is_binary(name) do
    with %AgentConfig{enabled: true, config: raw} = agent <- AgentConfigs.get_by_name(name),
         true <- is_map(raw),
         {:ok, config} <- normalize_config(raw["browser"]) do
      {:ok, agent, config}
    else
      _ -> unavailable()
    end
  end

  defp configuration(_), do: unavailable()

  defp normalize_config(config) when is_map(config) do
    profiles = config["profiles"]

    with true <-
           Map.keys(config) --
             ~w(default_profile node_executable helper_path profiles screenshot_result_mode) == [],
         mode = Map.get(config, "screenshot_result_mode", "image"),
         true <- mode in ~w(image path),
         true <- absolute?(config["node_executable"]) and absolute?(config["helper_path"]),
         true <- is_map(profiles) and map_size(profiles) in 1..8,
         true <-
           profile_name?(config["default_profile"]) and
             Map.has_key?(profiles, config["default_profile"]),
         {:ok, profiles} <- normalize_profiles(profiles) do
      {:ok, config |> Map.put("profiles", profiles) |> Map.put("screenshot_result_mode", mode)}
    else
      _ -> unavailable()
    end
  end

  defp normalize_config(_), do: unavailable()

  defp normalize_profiles(profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn {name, profile}, {:ok, normalized} ->
      if profile_name?(name) and is_map(profile) and profile_configuration?(profile) do
        profile =
          profile |> Map.put_new("timeout_ms", 15_000) |> Map.put_new("max_image_bytes", 196_608)

        if is_integer(profile["timeout_ms"]) and profile["timeout_ms"] in 1..120_000 and
             is_integer(profile["max_image_bytes"]) and profile["max_image_bytes"] in 1..196_608 do
          {:cont, {:ok, Map.put(normalized, name, profile)}}
        else
          {:halt, unavailable()}
        end
      else
        {:halt, unavailable()}
      end
    end)
  end

  defp profile_configuration?(%{"target" => "host", "driver" => "managed-host"} = profile) do
    Map.keys(profile) -- ~w(target driver executable data_dir timeout_ms max_image_bytes) == [] and
      absolute?(profile["executable"]) and absolute?(profile["data_dir"])
  end

  defp profile_configuration?(%{"target" => "host", "driver" => "remote-cdp"} = profile) do
    Map.keys(profile) -- ~w(target driver endpoint timeout_ms max_image_bytes) == [] and
      endpoint?(profile["endpoint"])
  end

  defp profile_configuration?(_), do: false

  defp endpoint?(endpoint) when is_binary(endpoint) do
    with true <- String.valid?(endpoint),
         {:ok, uri} <- URI.new(endpoint) do
      uri.scheme in ~w(http https ws wss) and is_binary(uri.host) and uri.host != ""
    else
      _ -> false
    end
  end

  defp endpoint?(_), do: false

  defp profile_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..128 and String.valid?(name) and
        Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, name)

  defp absolute?(path),
    do:
      is_binary(path) and String.valid?(path) and not String.contains?(path, "\0") and
        Path.type(path) == :absolute

  defp fingerprint(agent, config, project_root),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({agent.id, agent.name, config, project_root}, [:deterministic])
      )

  defp unavailable,
    do:
      failure(
        :unsupported_capability,
        "Browser requires enabled trusted Agent configuration with explicit node/helper paths, default_profile and 1..8 host profiles: managed-host executable/data_dir or remote-cdp endpoint"
      )

  defp failure(class, message), do: {:error, Error.new(class, message)}
end
