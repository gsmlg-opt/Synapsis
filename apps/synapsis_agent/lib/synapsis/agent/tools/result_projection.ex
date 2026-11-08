defmodule Synapsis.Agent.Tools.ResultProjection do
  @moduledoc """
  Projects public native tool results into durable, display-only host parts.

  The v1 projection is `%{"version" => 1, "result" => portable_native_map}`.
  Native fields and ordered content are retained without defining a backend
  result protocol. `content` on the part remains a legacy text view; media and
  structured values are available only in `projection`. Retaining a media block
  does not establish provider, resource-resolution or client-rendering support.

  Callers must provide public result data, never an execution context. Explicit
  auth/context keys and nonportable runtime values are rejected recursively;
  this cannot identify secrets embedded in arbitrary public strings. Runtime
  container keys are excluded even when their values are plain maps. Atom values
  are accepted only for supported `type`/`status` enums, plus nil and booleans;
  opaque metadata otherwise requires JSON values. Native payload budgets apply
  before JSON encoding. Runtime errors retain their class and portable details,
  use the existing safe display
  message, and omit their cause. Rejection proofs are checked by the native
  boundary and never persisted. No function dispatches or reconstructs a call.

  `ProviderMessages` uses this projection for native history and turn persistence.
  An optional original `:tool_name` supplies explicit presentation for native
  collaboration, local command and clock results; opaque fields remain retained.
  The exact native `view_image` shape is checked and adapted to bounded text and
  base64 image blocks before portability validation. Its bytes and data URL are
  not retained, and already-portable image replay never reconstructs them.
  """

  alias Backplane.AgentRuntime.{Error, ToolEffects}
  alias Backplane.AiProtocol.{Serialization, Validation}
  alias Synapsis.Agent.Runtime.ProviderMessages
  alias Synapsis.Part.ToolResult

  @denied_keys ~w(authorization proxyauthorization apikey accesstoken refreshtoken
    clientsecret password secret cookie setcookie backendcontext executioncontext providercontext
    authority operation resourceregistry workersupervisor)
  @limits Validation.default_limits()
  # Display-only v2 contracts retain source-complete Skills and ordinary native
  # Code Mode values and canonical read images. They grant no tool authority
  # or execution provenance and leave v1 budgets intact.
  @skill_names ~w(synapsis::skills_search synapsis::skills_read synapsis::skill synapsis::skill_workshop)
  @code_mode_names ~w(exec wait)
  @v2_names @skill_names ++ @code_mode_names ++ ["synapsis::read"]
  @skill_display_limits Map.merge(@limits, %{
                          max_bytes: 32 * 1_024 * 1_024,
                          max_string_bytes: 4 * 1_024 * 1_024
                        })
  @code_display_limits Map.merge(@limits, %{
                         max_bytes: 8 * 1_024 * 1_024,
                         max_string_bytes: 1_024 * 1_024
                       })
  @read_image_display_limits Map.merge(@limits, %{
                               max_bytes: 11_010_048,
                               max_string_bytes: 5_767_168
                             })
  @command_names ~w(exec_command write_stdin)
  @clock_names ~w(clock::curr_time clock::sleep)
  @image_mimes ~w(image/png image/jpeg image/gif image/webp)
  @image_metadata ~w(path detail mime_type bytes is_error)
  @image_raw_keys Enum.sort(@image_metadata ++ ~w(data image_url))
  @image_public_keys Enum.sort(@image_metadata ++ ~w(content))
  @patch_path_special ~r/[\p{Cc}\p{Zs}\p{Zl}\p{Zp}"\\]/u
  @patch_unicode_separators [0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000]
  @command_statuses ~w(running completed failed cancelled deadline_exceeded output_limit_exceeded
    execution_failure cancelling settling cleanup_failed)
  @cleanup_error_message "Command cleanup could not be confirmed"
  @error_classes ~w(validation forbidden approval_required not_found timeout cancelled
    transient_transport resource_conflict execution_failure malformed_result budget_exceeded
    unsupported_capability unknown_outcome overloaded)
  @enum_atoms %{
    "type" => ~w(text image reasoning tool_call refusal provider_state tool_result tool_error)a,
    "agent_status" => ~w(running interrupted shutdown pending_init)a,
    "previous_status" => ~w(running interrupted shutdown pending_init)a,
    "acceptance" => [:process_local],
    "errored" => [:startup_failure, :admission_failure],
    "termination_status" => [:not_requested, :requested],
    "cleanup_status" => [:not_started, :pending, :confirmed, :uncertain],
    "output_budget_unit" => [:estimated_token_bytes],
    "status" =>
      ~w(success error running completed incomplete failed cancelled interrupted shutdown yielded
        terminated created pending accepted reserved never_started active in_progress requested
        delivered cancel_requested granted denied updated applied confirmed retained staged published
        discovered revoked duplicate no_matches complete partial unknown paused blocked
        budget_limited usage_limited uncertain released done timed_out unknown_outcome
        deadline_exceeded output_limit_exceeded execution_failure cancelling settling cleanup_failed)a
  }

  @spec to_part(String.t(), term(), keyword()) :: {:ok, ToolResult.t()} | {:error, Error.t()}
  def to_part(tool_use_id, result, opts \\ [])

  def to_part(tool_use_id, result, opts)
      when is_binary(tool_use_id) and tool_use_id != "" and is_list(opts) do
    with true <- valid_opts?(opts),
         {:ok, native} <- native_result(result, tool_use_id, opts),
         {:ok, native} <- string_keys(native),
         native = Map.put_new(native, "is_error", false),
         true <- is_boolean(native["is_error"]),
         {:ok, native} <- public_native_patch(native, Keyword.get(opts, :tool_name)),
         {:ok, native} <- public_error(native),
         {:ok, native} <- public_command_cleanup(native, Keyword.get(opts, :tool_name)),
         {:ok, native} <- public_native_image(native, Keyword.get(opts, :tool_name)),
         {:ok, native} <- public_native_fetch(native, Keyword.get(opts, :tool_name)),
         {:ok, native} <- public_native_host_memory(native, Keyword.get(opts, :tool_name)),
         envelope = projection_envelope(native, Keyword.get(opts, :tool_name)),
         limits = projection_limits(envelope),
         {:ok, projection} <- portable(envelope, limits),
         {:ok, public} <- present_result(projection["result"], Keyword.get(opts, :tool_name)),
         {:ok, projection} <- portable(%{projection | "result" => public}, limits),
         {:ok, content} <- legacy_text(projection["result"]) do
      {:ok,
       %ToolResult{
         tool_use_id: tool_use_id,
         content: content,
         is_error: native["is_error"],
         projection: projection
       }}
    else
      _ -> invalid()
    end
  end

  def to_part(_, _, _), do: invalid()

  @doc "Reads a checked display projection; legacy strings are projected without rewriting the part."
  @spec from_part(ToolResult.t()) :: {:ok, map()} | {:error, Error.t()}
  def from_part(%ToolResult{content: content, is_error: is_error, projection: nil})
      when is_binary(content) and is_boolean(is_error) do
    portable(%{
      "version" => 1,
      "result" => %{"content" => content, "is_error" => is_error}
    })
  end

  def from_part(%ToolResult{content: content, is_error: is_error, projection: projection})
      when is_binary(content) and is_boolean(is_error) and is_map(projection) and
             map_size(projection) == 2 do
    with true <- Map.keys(projection) |> Enum.sort() == ["result", "version"],
         %{"version" => 1, "result" => result} when is_map(result) <- projection,
         true <- result["is_error"] === is_error,
         {:ok, checked} <- portable(projection),
         {:ok, _text} <- legacy_text(checked["result"]) do
      {:ok, checked}
    else
      _ -> invalid()
    end
  end

  def from_part(%ToolResult{
        content: content,
        is_error: is_error,
        projection: %{"version" => 2, "tool_name" => name, "result" => result} = projection
      })
      when is_binary(content) and is_boolean(is_error) and is_map(result) and
             map_size(projection) == 3 and
             name in @v2_names do
    with true <- result["is_error"] === is_error,
         true <- name != "synapsis::read" or filesystem_image?(result),
         {:ok, checked} <- portable(projection, projection_limits(projection)),
         {:ok, _text} <- legacy_text(checked["result"]) do
      {:ok, checked}
    else
      _ -> invalid()
    end
  end

  def from_part(_), do: invalid()

  defp native_result({:ok, result}, _, _) when is_map(result) and not is_struct(result),
    do: {:ok, result}

  defp native_result({:error, %Error{} = error}, _, _),
    do: {:ok, %{is_error: true, error: error}}

  defp native_result({:rejected, rejection}, tool_use_id, opts) do
    with operation when is_map(operation) <- Keyword.get(opts, :operation),
         true <- operation[:tool_call_id] === tool_use_id,
         {:ok, result} <- ToolEffects.validate_rejection(rejection, operation) do
      {:ok, result}
    else
      _ -> invalid()
    end
  end

  defp native_result(result, _, _) when is_map(result) and not is_struct(result),
    do: {:ok, result}

  defp native_result(_, _, _), do: invalid()

  defp valid_opts?(opts) do
    Keyword.keyword?(opts) and
      Enum.all?(opts, fn
        {:operation, operation} -> is_map(operation) and not is_struct(operation)
        {:tool_name, name} -> is_nil(name) or (is_binary(name) and name != "")
        _ -> false
      end) and length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts)))
  end

  # Host memory's authority is source state, not a native runtime binding.
  # Adapt only named host results at their known public paths before portability;
  # the backend/domain contract and generic reserved-key checks stay intact.
  defp public_native_host_memory(
         %{"is_error" => false, "structured" => structured} = result,
         "memory::get"
       ) do
    with {:ok, structured} <- string_keys(structured),
         %{
           "mode" => "online",
           "consistency" => "canonical",
           "stale" => false,
           "history_available" => true,
           "record" => record
         } <- structured,
         {:ok, structured} <- host_memory_authority(structured),
         {:ok, record} <- string_keys(record),
         {:ok, record} <- host_memory_record_authority(record) do
      {:ok, Map.put(result, "structured", Map.put(structured, "record", record))}
    else
      _ -> invalid()
    end
  end

  defp public_native_host_memory(%{"is_error" => false}, "memory::get"), do: invalid()

  defp public_native_host_memory(
         %{"is_error" => false, "structured" => structured} = result,
         "synapsis::memory_source_search"
       ) do
    with {:ok, structured} <- string_keys(structured) do
      case structured do
        %{
          "source" => source,
          "hits" => hits,
          "mode" => mode,
          "consistency" => _,
          "stale" => _,
          "history_available" => _,
          "pending_operations" => _
        }
        when is_map(source) and is_list(hits) and mode in ~w(online offline) ->
          with {:ok, source} <- string_keys(source),
               %{"id" => id, "endpoint" => endpoint, "partition" => "host_default"}
               when is_binary(id) and is_binary(endpoint) <- source,
               {:ok, structured} <-
                 host_recall_authority(
                   structured,
                   ~w(canonical canonical_with_provisional provisional)
                 ),
               {:ok, hits} <- host_recall_hits(hits) do
            {:ok, Map.put(result, "structured", Map.put(structured, "hits", hits))}
          else
            _ -> invalid()
          end

        _ ->
          {:ok, result}
      end
    end
  end

  defp public_native_host_memory(result, _), do: {:ok, result}

  defp host_memory_authority(%{"authority" => "canonical"} = public) do
    if Map.has_key?(public, "source_authority"),
      do: invalid(),
      else: {:ok, public |> Map.delete("authority") |> Map.put("source_authority", "canonical")}
  end

  # Replayed Parts already carry the public name.
  defp host_memory_authority(%{"source_authority" => "canonical"} = public) do
    if Map.has_key?(public, "authority"), do: invalid(), else: {:ok, public}
  end

  defp host_memory_authority(_), do: invalid()

  defp host_memory_record_authority(record) do
    if Map.has_key?(record, "authority") or Map.has_key?(record, "source_authority"),
      do: host_memory_authority(record),
      else: {:ok, record}
  end

  defp host_recall_authority(public, allowed) do
    case {Map.fetch(public, "authority"), Map.fetch(public, "source_authority")} do
      {{:ok, authority}, :error} ->
        if authority in allowed,
          do: {:ok, public |> Map.delete("authority") |> Map.put("source_authority", authority)},
          else: invalid()

      {:error, {:ok, authority}} ->
        if authority in allowed, do: {:ok, public}, else: invalid()

      _ ->
        invalid()
    end
  end

  defp host_recall_hits(hits) do
    Enum.reduce_while(hits, {:ok, []}, fn hit, {:ok, acc} ->
      with {:ok, hit} <- string_keys(hit),
           {:ok, hit} <- host_recall_hit_authority(hit) do
        {:cont, {:ok, [hit | acc]}}
      else
        _ -> {:halt, invalid()}
      end
    end)
    |> case do
      {:ok, hits} -> {:ok, Enum.reverse(hits)}
      error -> error
    end
  end

  defp host_recall_hit_authority(hit) do
    if Map.has_key?(hit, "authority") or Map.has_key?(hit, "source_authority"),
      do: host_recall_authority(hit, ~w(canonical provisional)),
      else: {:ok, hit}
  end

  # Patch evidence is a finite public shape, not an extension of generic atom
  # metadata. Diagnostic errors may contain runtime values: retain only checked
  # completion evidence before the ordinary portability/serialization boundary.
  defp public_native_patch(%{"is_error" => false} = result, "apply_patch") do
    with true <- Map.keys(result) -- ~w(is_error status files content) == [],
         true <- result["status"] in [:applied, "applied"],
         {:ok, files, _budget} <- patch_files(result["files"], {0, 0}),
         public = %{"is_error" => false, "status" => "applied", "files" => files},
         {:ok, public} <- patch_content(public, "Patch applied", files, [], false),
         true <- canonical_patch_content?(result, public) do
      {:ok, public}
    else
      _ -> invalid()
    end
  end

  defp public_native_patch(%{"is_error" => true} = result, "apply_patch") do
    with true <- Map.keys(result) -- ~w(is_error error content) == [],
         {:ok, class, details} <- patch_error(result["error"]),
         {:ok, details} <- string_keys(details),
         {:ok, files, budget} <- patch_files(Map.get(details, "files", []), {0, 0}),
         {:ok, uncertain, _budget} <-
           patch_uncertain(Map.get(details, "uncertain_files", []), budget, 0, []),
         details = Map.take(details, ~w(files uncertain_files)),
         details =
           if(Map.has_key?(details, "files"), do: Map.put(details, "files", files), else: details),
         details =
           if(Map.has_key?(details, "uncertain_files"),
             do: Map.put(details, "uncertain_files", uncertain),
             else: details
           ),
         message = "Patch failed (" <> class <> ")",
         public = %{
           "is_error" => true,
           "error" => %{"class" => class, "message" => message, "details" => details}
         },
         {:ok, public} <- patch_content(public, message, files, uncertain, true),
         true <- canonical_patch_content?(result, public) do
      {:ok, public}
    else
      _ -> invalid()
    end
  end

  defp public_native_patch(result, _), do: {:ok, result}

  defp patch_error(%Error{class: class, details: details})
       when is_atom(class) and is_map(details) and not is_struct(details) do
    class = Atom.to_string(class)
    if class in @error_classes, do: {:ok, class, details}, else: invalid()
  end

  defp patch_error(error) when is_map(error) and not is_struct(error) do
    with {:ok, error} <- string_keys(error),
         true <- Enum.sort(Map.keys(error)) == ~w(class details message),
         class when class in @error_classes <- error["class"],
         true <- error["message"] == "Patch failed (" <> class <> ")",
         details when is_map(details) and not is_struct(details) <- error["details"] do
      {:ok, class, details}
    else
      _ -> invalid()
    end
  end

  defp patch_error(_), do: invalid()

  defp patch_files(files, budget), do: patch_files(files, budget, 0, [])
  defp patch_files([], budget, _, acc), do: {:ok, Enum.reverse(acc), budget}

  defp patch_files([file | rest], budget, count, acc)
       when count < @limits.max_list_length do
    with {:ok, file} <- string_keys(file),
         {:ok, action} <- patch_action(file["action"]),
         true <-
           Enum.sort(Map.keys(file)) ==
             if(action == "moved", do: ~w(action from path), else: ~w(action path)),
         true <- patch_path?(file["path"]),
         true <- action != "moved" or patch_path?(file["from"]),
         file = Map.put(file, "action", action),
         {:ok, file, budget} <- bounded_value(file, nil, 4, budget) do
      patch_files(rest, budget, count + 1, [file | acc])
    else
      _ -> invalid()
    end
  end

  defp patch_files(_, _, _, _), do: invalid()

  defp patch_action(action) when action in [:added, :updated, :deleted, :moved],
    do: {:ok, Atom.to_string(action)}

  defp patch_action(action) when action in ~w(added updated deleted moved), do: {:ok, action}
  defp patch_action(_), do: invalid()

  defp patch_path?(path) when is_binary(path) and byte_size(path) <= @limits.max_string_bytes,
    do: String.valid?(path)

  defp patch_path?(_), do: false

  defp patch_uncertain([], budget, _, acc), do: {:ok, Enum.reverse(acc), budget}

  defp patch_uncertain([path | rest], budget, count, acc)
       when count < @limits.max_list_length do
    with true <- patch_path?(path),
         {:ok, path, budget} <- bounded_value(path, nil, 4, budget) do
      patch_uncertain(rest, budget, count + 1, [path | acc])
    else
      _ -> invalid()
    end
  end

  defp patch_uncertain(_, _, _, _), do: invalid()

  # Count the complete repeated public text before allocating it or JSON. A path
  # may fit alone while its evidence plus summary exceeds the native budget.
  defp patch_content(public, title, files, uncertain, failed?) do
    prefix = if failed?, do: "Completed - ", else: ""

    size =
      Enum.reduce(files, byte_size(title), fn file, size ->
        size + 1 + byte_size(prefix) + byte_size(patch_label(file["action"])) +
          patch_display_size(file["path"]) +
          if(file["action"] == "moved", do: patch_display_size(file["from"]) + 4, else: 0)
      end)

    size =
      Enum.reduce(
        uncertain,
        size,
        &(patch_display_size(&1) + byte_size("\nUnknown outcome: ") + &2)
      )

    with true <- size <= @limits.max_string_bytes,
         {:ok, _, {_, bytes}} <-
           bounded_value(
             %{"version" => 1, "result" => Map.put(public, "content", "")},
             nil,
             1,
             {0, 0}
           ),
         true <- bytes + size <= @limits.max_bytes do
      lines =
        Enum.map(files, fn file ->
          path =
            if(file["action"] == "moved",
              do: [patch_display(file["from"]), " -> ", patch_display(file["path"])],
              else: patch_display(file["path"])
            )

          ["\n", prefix, patch_label(file["action"]), path]
        end)

      unknown = Enum.map(uncertain, &["\nUnknown outcome: ", patch_display(&1)])
      {:ok, Map.put(public, "content", IO.iodata_to_binary([title, lines, unknown]))}
    else
      _ -> invalid()
    end
  end

  defp patch_label("added"), do: "Added: "
  defp patch_label("updated"), do: "Updated: "
  defp patch_label("deleted"), do: "Deleted: "
  defp patch_label("moved"), do: "Moved: "

  # Evidence keeps the original UTF8 path. Only its display is quoted when it
  # contains ambiguous whitespace, quotes or controls. Count escapes without
  # allocating an escaped path; construct them only after the summary fits.
  defp patch_quoted?(path), do: path == "" or String.match?(path, @patch_path_special)

  defp patch_display_size(path) do
    if patch_quoted?(path), do: patch_escaped_size(path, 2), else: byte_size(path)
  end

  defp patch_escaped_size(<<>>, size), do: size

  defp patch_escaped_size(<<codepoint::utf8, rest::binary>> = path, size) do
    bytes =
      case patch_escape_kind(codepoint) do
        :short -> 2
        :unicode -> 6
        :literal -> byte_size(path) - byte_size(rest)
      end

    patch_escaped_size(rest, size + bytes)
  end

  defp patch_display(path) do
    if patch_quoted?(path),
      do: ["\"", Regex.replace(@patch_path_special, path, &patch_escape_character/1), "\""],
      else: path
  end

  defp patch_escape_kind(codepoint) when codepoint in [8, 9, 10, 12, 13, 34, 92], do: :short

  defp patch_escape_kind(codepoint)
       when codepoint < 32 or codepoint in 0x7F..0x9F or codepoint in 0x2000..0x200A or
              codepoint in @patch_unicode_separators,
       do: :unicode

  defp patch_escape_kind(_), do: :literal

  defp patch_escape_character(<<codepoint::utf8>> = character) do
    case patch_escape_kind(codepoint) do
      :literal ->
        character

      :unicode ->
        "\\u" <>
          (codepoint |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))

      :short ->
        case codepoint do
          8 -> "\\b"
          9 -> "\\t"
          10 -> "\\n"
          12 -> "\\f"
          13 -> "\\r"
          34 -> "\\\""
          92 -> "\\\\"
        end
    end
  end

  defp canonical_patch_content?(original, public),
    do: not Map.has_key?(original, "content") or original["content"] == public["content"]

  # Native view_image is the one known result whose public payload contains
  # non-UTF8 bytes. Adapt only its finite shape before generic portability checks.
  # The projection retains one base64 payload, never raw bytes or the data URL.
  defp public_native_image(%{"is_error" => false} = result, "view_image") do
    with {:ok, summary} <- image_summary(result) do
      case Enum.sort(Map.keys(result)) do
        @image_raw_keys -> project_raw_image(result, summary)
        @image_public_keys -> check_public_image(result, summary)
        _ -> invalid()
      end
    end
  end

  defp public_native_image(%{"is_error" => true} = result, "view_image") do
    if Enum.any?(~w(path detail mime_type bytes data image_url), &Map.has_key?(result, &1)),
      do: invalid(),
      else: {:ok, result}
  end

  defp public_native_image(result, _), do: {:ok, result}

  defp image_summary(%{"path" => path, "detail" => detail, "mime_type" => mime, "bytes" => bytes})
       when is_binary(path) and detail in ~w(high original) and mime in @image_mimes and
              is_integer(bytes) and bytes > 0 and bytes <= div(@limits.max_string_bytes, 4) * 3 do
    suffix = "\nDetail: #{detail}\nMIME type: #{mime}\nBytes: #{bytes}"

    with true <-
           byte_size(path) + byte_size(suffix) + byte_size("Image: ") <= @limits.max_string_bytes,
         true <- String.valid?(path) and String.trim(path) != "",
         false <- String.match?(path, ~r/[\x00-\x1f\x7f]/) do
      {:ok, "Image: " <> path <> suffix}
    else
      _ -> invalid()
    end
  end

  defp image_summary(_), do: invalid()

  defp project_raw_image(%{"data" => data, "image_url" => url} = result, summary)
       when is_binary(data) and is_binary(url) do
    bytes = result["bytes"]
    encoded_size = 4 * div(bytes + 2, 3)
    prefix = "data:" <> result["mime_type"] <> ";base64,"
    prefix_size = byte_size(prefix)
    skeleton = image_projection(result, summary, "")

    with true <- byte_size(data) == bytes,
         true <- byte_size(url) == prefix_size + encoded_size,
         true <- binary_part(url, 0, prefix_size) == prefix,
         {:ok, _, {_, public_bytes}} <-
           bounded_value(%{"version" => 1, "result" => skeleton}, nil, 1, {0, 0}),
         true <- public_bytes + encoded_size <= @limits.max_bytes,
         encoded = Base.encode64(data),
         true <- binary_part(url, prefix_size, encoded_size) == encoded do
      {:ok, image_projection(result, summary, encoded)}
    else
      _ -> invalid()
    end
  end

  defp project_raw_image(_, _), do: invalid()

  # Replayed results already contain portable content. Check that representation
  # directly; replay never recreates a native raw-byte result or data URL.
  defp check_public_image(%{"content" => [text, image]} = result, summary) do
    with %{"type" => "text", "text" => ^summary} when map_size(text) == 2 <- text,
         %{"type" => "image", "data" => source} when map_size(image) == 2 <- image,
         %{"source" => "base64", "media_type" => mime, "data" => encoded}
         when map_size(source) == 3 and is_binary(encoded) <- source,
         true <- mime == result["mime_type"],
         true <- canonical_image_base64?(encoded, result["bytes"]) do
      {:ok, result}
    else
      _ -> invalid()
    end
  end

  defp check_public_image(_, _), do: invalid()

  defp canonical_image_base64?(encoded, bytes) do
    padding = rem(3 - rem(bytes, 3), 3)
    payload_size = byte_size(encoded) - padding

    byte_size(encoded) == 4 * div(bytes + 2, 3) and
      payload_size > 0 and
      binary_part(encoded, payload_size, padding) == String.duplicate("=", padding) and
      String.match?(binary_part(encoded, 0, payload_size), ~r/\A[A-Za-z0-9+\/]+\z/) and
      canonical_image_tail?(binary_part(encoded, payload_size - 1, 1), padding)
  end

  defp canonical_image_tail?(_, 0), do: true
  defp canonical_image_tail?(tail, 1), do: tail in ~w(A E I M Q U Y c g k o s w 0 4 8)
  defp canonical_image_tail?(tail, 2), do: tail in ~w(A Q g w)

  defp image_projection(result, summary, encoded) do
    result
    |> Map.take(@image_metadata)
    |> Map.put("content", [
      %{"type" => "text", "text" => summary},
      %{
        "type" => "image",
        "data" => %{"source" => "base64", "media_type" => result["mime_type"], "data" => encoded}
      }
    ])
  end

  # Readable native documents retain all public metadata and one JSON model view.
  defp public_native_fetch(
         %{
           "is_error" => false,
           "url" => url,
           "final_url" => final_url,
           "text" => text,
           "content_type" => type
         } = result,
         "web::fetch"
       )
       when is_binary(url) and is_binary(final_url) and is_binary(text) and
              is_binary(type) and type != "" do
    document = Map.drop(result, ["content", "is_error"])

    case Jason.encode(document) do
      {:ok, content} -> {:ok, Map.put(result, "content", content)}
      _ -> invalid()
    end
  end

  # Native fetch headers are transport metadata and may contain nonportable tuples.
  # Persist only public resource data, with the body as the model-visible text.
  defp public_native_fetch(
         %{
           "is_error" => false,
           "body" => body,
           "url" => url,
           "status" => status,
           "content_type" => type
         } = result,
         "web::fetch"
       )
       when is_binary(body) and is_binary(url) and is_integer(status) and status in 100..599 and
              (is_binary(type) or is_nil(type)) do
    {:ok,
     result |> Map.take(~w(is_error body url status content_type)) |> Map.put("content", body)}
  end

  defp public_native_fetch(%{"is_error" => false}, "web::fetch"), do: invalid()
  defp public_native_fetch(result, _), do: {:ok, result}

  defp present_result(%{"is_error" => false, "status" => status} = result, name)
       when name in ["exec", "wait"] and status in ["yielded", "completed", "terminated"] do
    output = Map.get(result, "output", [])

    if is_list(output) and Enum.all?(output, &is_map/1) and
         optional_field?(result, "cell_id", &(is_binary(&1) and &1 != "")) and
         optional_field?(result, "output_truncated", &is_boolean/1) and
         (status != "yielded" or is_binary(result["cell_id"])) do
      lines = ["Status: " <> status]
      lines = append_field(lines, result, "cell_id", "Cell ID")
      lines = append_field(lines, result, "output_truncated", "Output truncated")
      content = output ++ [%{"type" => "text", "text" => Enum.join(lines, "\n")}]
      {:ok, Map.put(result, "content", content)}
    else
      invalid()
    end
  end

  defp present_result(%{"is_error" => false} = result, name)
       when name in @command_names or name in @clock_names do
    with {:ok, text} <- local_text(name, result),
         do: {:ok, Map.put(result, "content", text)}
  end

  defp present_result(
         %{"is_error" => false, "tools" => tools, "publication" => publication} = result,
         "tool_search"
       )
       when is_list(tools) and is_map(publication) do
    with true <- Enum.all?(tools, &(is_map(&1) and is_binary(&1["name"]))),
         status when is_binary(status) <- publication["status"],
         {:ok, summary} <-
           Serialization.to_json(%{"tools" => tools, "publication" => publication}) do
      {:ok, Map.put(result, "content", summary)}
    else
      _ -> invalid()
    end
  end

  defp present_result(%{"content" => _} = result, _), do: {:ok, result}
  defp present_result(%{"is_error" => true} = result, _), do: {:ok, result}
  defp present_result(result, nil), do: {:ok, result}

  defp present_result(result, name) do
    with {:ok, text} <- collaboration_text(name, result),
         do: {:ok, Map.put(result, "content", text)}
  end

  defp local_text(
         name,
         %{"output" => output, "status" => status, "wall_time_seconds" => elapsed} = result
       )
       when name in @command_names and is_binary(output) and status in @command_statuses and
              is_number(elapsed) and elapsed >= 0 do
    checks = [
      {"exit_code", &nonnegative_integer?/1},
      {"session_id", &(is_integer(&1) and &1 > 0)},
      {"termination_status", &(&1 in ~w(not_requested requested))},
      {"cleanup_status", &(&1 in ~w(not_started pending confirmed uncertain))},
      {"output_limit_exceeded?", &is_boolean/1},
      {"output_truncated", &is_boolean/1},
      {"omitted_output_bytes", &nonnegative_integer?/1},
      {"output_budget_unit", &(&1 == "estimated_token_bytes")}
    ]

    if Enum.all?(checks, fn {key, check} -> optional_field?(result, key, check) end) do
      lines = ["Status: " <> status]
      lines = append_field(lines, result, "exit_code", "Exit code")
      lines = append_field(lines, result, "session_id", "Session ID")
      lines = lines ++ ["Wall time: #{elapsed} seconds"]
      lines = append_field(lines, result, "termination_status", "Termination")
      lines = append_field(lines, result, "cleanup_status", "Cleanup")

      lines =
        append_field(lines, result, "cleanup_error", "Cleanup error", fn error ->
          error["message"]
        end)

      lines = append_field(lines, result, "output_truncated", "Output truncated")
      lines = append_field(lines, result, "omitted_output_bytes", "Omitted output bytes")
      lines = append_field(lines, result, "output_budget_unit", "Output budget unit")
      lines = append_field(lines, result, "output_limit_exceeded?", "Output limit exceeded")
      metadata = Enum.join(lines, "\n")
      {:ok, if(output == "", do: metadata, else: output <> "\n\n" <> metadata)}
    else
      invalid()
    end
  end

  defp local_text("clock::curr_time", %{"current_time" => time})
       when is_binary(time) and time != "",
       do: {:ok, "Current time: " <> time}

  defp local_text("clock::sleep", %{"wall_time_seconds" => elapsed})
       when is_number(elapsed) and elapsed >= 0,
       do: {:ok, "Wall time: #{elapsed} seconds"}

  defp local_text(_, _), do: invalid()

  defp optional_field?(result, key, check) do
    case Map.fetch(result, key) do
      :error -> true
      {:ok, value} -> check.(value)
    end
  end

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp append_field(lines, result, key, label, format \\ &to_string/1) do
    case Map.fetch(result, key) do
      :error -> lines
      {:ok, value} -> lines ++ [label <> ": " <> format.(value)]
    end
  end

  # Cleanup errors are diagnostic containers, not public command output. Strip
  # their details and cause before portability checks can encounter runtime data.
  defp public_command_cleanup(result, name) when name in @command_names do
    case Map.fetch(result, "cleanup_error") do
      :error ->
        {:ok, result}

      {:ok, error} ->
        with {:ok, public} <- cleanup_error(error),
             do: {:ok, Map.put(result, "cleanup_error", public)}
    end
  end

  defp public_command_cleanup(result, _), do: {:ok, result}

  defp cleanup_error(%Error{} = error) do
    with %Error{} <- Error.new(error.class),
         true <- is_map(error.details) and not is_struct(error.details) do
      {:ok, %{"class" => Atom.to_string(error.class), "message" => @cleanup_error_message}}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp cleanup_error(%{"class" => class, "message" => @cleanup_error_message} = error)
       when map_size(error) == 2 and class in @error_classes,
       do: {:ok, error}

  defp cleanup_error(_), do: invalid()

  defp collaboration_text("spawn_agent", %{"task_name" => name}) when is_binary(name),
    do: {:ok, "Spawned agent " <> name}

  defp collaboration_text("followup_task", %{"accepted" => true}),
    do: {:ok, "Follow-up task accepted"}

  defp collaboration_text("send_message", %{"accepted" => true, "message_id" => id})
       when is_binary(id),
       do: {:ok, "Message accepted: " <> id}

  defp collaboration_text("wait_agent", %{"message" => message, "timed_out" => timed_out})
       when is_binary(message) and is_boolean(timed_out),
       do: {:ok, message}

  defp collaboration_text("interrupt_agent", %{"previous_status" => previous, "status" => status}) do
    with {:ok, previous} <- status_text(previous),
         {:ok, status} <- status_text(status),
         do: {:ok, "Agent interrupted: " <> previous <> " -> " <> status}
  end

  defp collaboration_text("list_agents", %{"agents" => agents}) when is_list(agents) do
    Enum.reduce_while(agents, {:ok, []}, fn
      %{"agent_name" => name, "agent_status" => status}, {:ok, lines} when is_binary(name) ->
        case status_text(status) do
          {:ok, status} -> {:cont, {:ok, [name <> ": " <> status | lines]}}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, invalid()}
    end)
    |> case do
      {:ok, []} -> {:ok, "No agents"}
      {:ok, lines} -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp collaboration_text(_, _), do: invalid()

  defp status_text(status) when status in ~w(running interrupted shutdown pending_init),
    do: {:ok, status}

  defp status_text(%{"completed" => text}) when is_binary(text), do: {:ok, "completed: " <> text}

  # Portable bounds already checked every block. Reasoning and provider state
  # remain in the projection; only explicit text contributes to the status label.
  defp status_text(%{"completed" => blocks}) when is_list(blocks) do
    Enum.reduce_while(blocks, {:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, texts} when is_binary(text) ->
        {:cont, {:ok, [text | texts]}}

      %{"type" => "reasoning", "text" => text} = block, acc when is_binary(text) ->
        states = Map.get(block, "provider_states", [])

        if (is_nil(block["signature"]) or is_binary(block["signature"])) and
             is_list(states) and Enum.all?(states, &is_map/1),
           do: {:cont, acc},
           else: {:halt, invalid()}

      %{"type" => "provider_state", "state" => state}, acc when is_map(state) ->
        {:cont, acc}

      _, _ ->
        {:halt, invalid()}
    end)
    |> case do
      {:ok, texts} ->
        text = texts |> Enum.reverse() |> Enum.join("\n")
        {:ok, if(text == "", do: "completed", else: "completed: " <> text)}

      error ->
        error
    end
  end

  defp status_text(%{"errored" => text}) when is_binary(text), do: {:ok, "errored: " <> text}

  defp status_text(%{"unknown_outcome" => text}) when is_binary(text),
    do: {:ok, "unknown_outcome: " <> text}

  defp status_text(_), do: invalid()

  defp public_error(%{"is_error" => true, "error" => %Error{} = error} = result) do
    with %Error{} <- Error.new(error.class),
         true <- is_map(error.details) and not is_struct(error.details),
         {:ok, message} <- ProviderMessages.tool_result_text(%{is_error: true, error: error}) do
      {:ok,
       Map.put(result, "error", %{
         "class" => Atom.to_string(error.class),
         "message" => message,
         "details" => error.details
       })}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp public_error(result), do: {:ok, result}

  defp legacy_text(%{"content" => content}) when is_binary(content), do: {:ok, content}

  defp legacy_text(%{"content" => content}) when is_list(content) do
    Enum.reduce_while(content, {:ok, []}, fn
      %{"type" => "text", "text" => text}, {:ok, texts} when is_binary(text) ->
        {:cont, {:ok, [text | texts]}}

      %{"type" => "text"}, _ ->
        {:halt, invalid()}

      _block, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, texts} -> {:ok, texts |> Enum.reverse() |> Enum.join("\n")}
      error -> error
    end
  end

  defp legacy_text(%{"is_error" => true, "error" => %{"message" => message}})
       when message in [
              "Tool denied by capability policy",
              "Tool registration changed",
              "Tool denied: tool is not in this run catalog"
            ],
       do: {:ok, message}

  defp legacy_text(%{"is_error" => true}), do: {:ok, "Tool execution failed"}
  defp legacy_text(_), do: {:ok, ""}

  # A named read v2 is only a finite display contract for the unchanged source
  # image envelope. It does not establish the result's execution origin.
  defp projection_envelope(result, "synapsis::read") do
    if filesystem_image?(result),
      do: %{"version" => 2, "tool_name" => "synapsis::read", "result" => result},
      else: %{"version" => 1, "result" => result}
  end

  defp projection_envelope(result, name) when name in @v2_names,
    do: %{"version" => 2, "tool_name" => name, "result" => result}

  defp projection_envelope(result, _name), do: %{"version" => 1, "result" => result}

  defp projection_limits(%{"version" => 2, "tool_name" => name}) when name in @skill_names,
    do: @skill_display_limits

  defp projection_limits(%{"version" => 2, "tool_name" => name}) when name in @code_mode_names,
    do: @code_display_limits

  defp projection_limits(%{"version" => 2, "tool_name" => "synapsis::read"}),
    do: @read_image_display_limits

  defp projection_limits(_), do: @limits

  defp filesystem_image?(
         %{"is_error" => false, "content" => [text, image], "details" => details} = result
       )
       when map_size(result) == 3 do
    with {:ok, text} <- string_keys(text),
         %{"type" => "text", "text" => summary}
         when map_size(text) == 2 and is_binary(summary) and summary != "" <- text,
         {:ok, image} <- string_keys(image),
         %{"type" => "image", "data" => data, "mimeType" => mime}
         when map_size(image) == 3 and is_binary(data) and data != "" and mime in @image_mimes <-
           image,
         {:ok, details} <- string_keys(details),
         %{"kind" => "image", "content" => ^summary, "mimeType" => ^mime}
         when map_size(details) == 3 <- details do
      true
    else
      _ -> false
    end
  end

  defp filesystem_image?(_), do: false

  # Bound and normalize before allocating JSON. Native validation remains the
  # final portable-value check; JSON is never used as a display fallback.
  defp portable(value, limits \\ @limits) do
    with {:ok, portable, _budget} <- bounded_value(value, nil, 1, {0, 0}, limits),
         :ok <- Validation.term(portable, limits),
         {:ok, json} <- Serialization.to_json(portable),
         {:ok, portable} <- Serialization.from_json(json, max_encoded_bytes: limits.max_bytes) do
      {:ok, portable}
    else
      _ -> invalid()
    end
  end

  defp bounded_value(value, field, depth, budget),
    do: bounded_value(value, field, depth, budget, @limits)

  defp bounded_value(value, field, depth, {nodes, bytes}, limits)
       when nodes < limits.max_nodes do
    normalize_value(value, field, depth, {nodes + 1, bytes}, limits)
  end

  defp bounded_value(_, _, _, _, _), do: invalid()
  defp normalize_value(value, _, _, _, _limits) when is_struct(value), do: invalid()

  defp normalize_value(value, _, depth, budget, limits)
       when is_map(value) and map_size(value) <= limits.max_map_entries and
              depth <= limits.max_depth do
    Enum.reduce_while(value, {:ok, %{}, budget}, fn {key, value}, {:ok, acc, budget} ->
      with true <- is_atom(key) or is_binary(key),
           key = to_string(key),
           {:ok, budget} <- bounded_string(key, budget, limits),
           false <- denied_key?(key) or Map.has_key?(acc, key),
           {:ok, normalized, budget} <- bounded_value(value, key, depth + 1, budget, limits) do
        {:cont, {:ok, Map.put(acc, key, normalized), budget}}
      else
        _ -> {:halt, invalid()}
      end
    end)
  end

  defp normalize_value(value, _, depth, budget, limits)
       when is_list(value) and depth <= limits.max_depth,
       do: bounded_list(value, depth, budget, 0, [], limits)

  defp normalize_value(value, _, _, budget, limits) when is_binary(value) do
    with {:ok, budget} <- bounded_string(value, budget, limits), do: {:ok, value, budget}
  end

  defp normalize_value(value, _, _, budget, _limits)
       when is_number(value) or value in [nil, true, false],
       do: {:ok, value, budget}

  defp normalize_value(value, field, _, budget, limits) when is_atom(value) do
    if value in Map.get(@enum_atoms, field, []) do
      value = Atom.to_string(value)
      with {:ok, budget} <- bounded_string(value, budget, limits), do: {:ok, value, budget}
    else
      invalid()
    end
  end

  defp normalize_value(_, _, _, _, _), do: invalid()

  defp bounded_list([], _, budget, _, acc, _limits), do: {:ok, Enum.reverse(acc), budget}

  defp bounded_list([value | rest], depth, budget, count, acc, limits)
       when count < limits.max_list_length do
    with {:ok, normalized, budget} <- bounded_value(value, nil, depth + 1, budget, limits) do
      bounded_list(rest, depth, budget, count + 1, [normalized | acc], limits)
    end
  end

  defp bounded_list(_, _, _, _, _, _), do: invalid()

  defp bounded_string(value, {nodes, bytes}, limits)
       when byte_size(value) <= limits.max_string_bytes and
              bytes + byte_size(value) <= limits.max_bytes do
    if String.valid?(value), do: {:ok, {nodes, bytes + byte_size(value)}}, else: invalid()
  end

  defp bounded_string(_, _, _), do: invalid()

  defp string_keys(value)
       when is_map(value) and not is_struct(value) and map_size(value) <= @limits.max_map_entries do
    Enum.reduce_while(value, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(acc, key),
          do: {:halt, invalid()},
          else: {:cont, {:ok, Map.put(acc, key, value)}}

      _, _ ->
        {:halt, invalid()}
    end)
  end

  defp string_keys(_), do: invalid()

  defp denied_key?(key) do
    key |> String.downcase() |> String.replace(["-", "_", " "], "") |> then(&(&1 in @denied_keys))
  end

  defp invalid, do: {:error, Error.new(:malformed_result, "Tool result cannot be projected")}
end
