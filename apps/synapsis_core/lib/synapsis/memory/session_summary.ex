defmodule Synapsis.Memory.SessionSummary do
  @moduledoc """
  Bounded candidate extraction from a persisted session or trusted live snapshot.

  Candidates are returned for review and are never saved. Full history is
  chronological; legacy recent selection deliberately returns the newest ten
  messages in reverse chronology. Range indices use an exclusive end.

  Limits are 200 messages, 128 KiB of transcript text, 64 KiB of provider text
  and public output, and a 30-second total deadline shortened by `:deadline`.
  A guardian monitors the caller and owns a bounded-heap worker. The worker uses
  an owner-linked provider stream, so cancellation also terminates HTTP work.
  The synchronous wait belongs in a native effect task, never a session worker.

  The trusted `:messages` option supplies host-domain messages from the live
  session authority. Without it the durable transcript is explicitly labelled.
  Provider/model selection always comes from session metadata and provider policy.
  """

  alias Synapsis.Provider.Adapter
  alias Synapsis.Session.Store

  @kinds ~w(fact decision lesson preference pattern warning)
  @default_kinds ~w(fact decision lesson preference pattern)
  @timeout 30_000
  @text_limit 131_072
  @output_limit 65_536

  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "scope" => %{"type" => "string", "enum" => ~w(full recent range), "default" => "full"},
        "message_range" => %{
          "type" => "array",
          "minItems" => 2,
          "maxItems" => 2,
          "items" => %{"type" => "integer", "minimum" => 0, "maximum" => 200}
        },
        "focus" => %{"type" => "string", "maxLength" => 512},
        "kinds" => %{
          "type" => "array",
          "maxItems" => 6,
          "items" => %{"type" => "string", "enum" => @kinds}
        },
        "use_llm" => %{"type" => "boolean", "default" => true}
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  def validate(args) when is_map(args) and not is_struct(args) do
    scope = Map.get(args, "scope", "full")
    range = Map.get(args, "message_range")
    kinds = Map.get(args, "kinds", @default_kinds)

    if Map.keys(args) -- ~w(scope message_range focus kinds use_llm) == [] and
         scope in ~w(full recent range) and
         (not Map.has_key?(args, "message_range") or range?(range)) and
         (scope != "range" or range?(range)) and
         (not Map.has_key?(args, "focus") or text?(args["focus"], 512)) and
         is_list(kinds) and length(kinds) <= 6 and Enum.all?(kinds, &(&1 in @kinds)) and
         is_boolean(Map.get(args, "use_llm", true)),
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate(_), do: {:error, :invalid_input}

  def summarize(session_id, args, opts \\ []) do
    with :ok <- validate(args),
         true <- is_binary(session_id) and match?({:ok, ^session_id}, Ecto.UUID.cast(session_id)),
         true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- [:deadline, :messages] == [] do
      bounded(opts, fn -> summarize_session(session_id, args, opts) end)
    else
      false -> {:error, :invalid_context}
      {:error, _} = error -> error
    end
  end

  defp range?([first, last]),
    do: is_integer(first) and is_integer(last) and first >= 0 and last >= first and last <= 200

  defp range?(_), do: false

  defp text?(value, limit),
    do: is_binary(value) and byte_size(value) <= limit and String.valid?(value)

  defp summarize_session(id, args, opts) do
    with {:ok, meta} <- metadata(id),
         {:ok, messages, source} <- messages(id, args, opts),
         :ok <- transcript(messages) do
      if messages == [] do
        {:ok,
         %{
           source: source,
           extraction: "heuristic",
           candidates: [],
           message: "No messages to summarize"
         }}
      else
        focus = args["focus"]
        kinds = Map.get(args, "kinds", @default_kinds)

        {extraction, candidates} =
          if Map.get(args, "use_llm", true) do
            case extract_llm(messages, focus, kinds, meta) do
              {:ok, candidates} -> {"llm", candidates}
              {:error, _} -> {"heuristic", heuristic(messages, focus, kinds)}
            end
          else
            {"heuristic", heuristic(messages, focus, kinds)}
          end

        result = %{
          source: source,
          extraction: extraction,
          candidates: candidates,
          message_count: length(messages)
        }

        if byte_size(Jason.encode!(result)) <= @output_limit,
          do: {:ok, result},
          else: {:error, :output_limit}
      end
    end
  end

  defp metadata(id) do
    case Store.get_meta(id) do
      {:ok, %{id: ^id} = meta} -> {:ok, meta}
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :storage_failed}
    end
  end

  defp messages(id, args, opts) do
    scope = Map.get(args, "scope", "full")

    {messages, source} =
      case Keyword.fetch(opts, :messages) do
        {:ok, messages} ->
          {messages, "live_session"}

        :error ->
          {Synapsis.Message.list_recent_by_session(id, if(scope == "recent", do: 10, else: 201)),
           "durable_session"}
      end

    cond do
      not is_list(messages) ->
        {:error, :invalid_context}

      scope != "recent" and length(messages) > 200 ->
        {:error, :message_limit}

      true ->
        selected =
          case scope do
            "recent" ->
              messages |> Enum.reverse() |> Enum.take(10)

            "range" ->
              [first, last] = args["message_range"]
              Enum.slice(messages, first, last - first)

            _ ->
              messages
          end

        {:ok, selected, source}
    end
  end

  defp transcript(messages) do
    cond do
      :erlang.external_size(messages) > 262_144 ->
        {:error, :transcript_limit}

      not Enum.all?(messages, &(is_map(&1) and is_list(Map.get(&1, :parts, [])))) ->
        {:error, :invalid_context}

      true ->
        texts = Enum.flat_map(messages, &texts/1)

        if Enum.all?(texts, &String.valid?/1) and
             Enum.reduce(texts, 0, &(byte_size(&1) + &2)) <= @text_limit,
           do: :ok,
           else: {:error, :transcript_limit}
    end
  end

  defp texts(message) do
    Enum.flat_map(Map.get(message, :parts, []), fn
      %Synapsis.Part.Text{content: text} when is_binary(text) -> [text]
      %{type: "text", content: text} when is_binary(text) -> [text]
      %{"type" => "text", "content" => text} when is_binary(text) -> [text]
      _ -> []
    end)
  end

  defp extract_llm(messages, focus, kinds, meta) do
    provider = meta[:provider] || "anthropic"

    with {:ok, config} <- Synapsis.Providers.runtime_config(provider) do
      model = config[:default_model] || Synapsis.Providers.model_for_tier(provider, :fast)
      type = config[:type] || config["type"] || provider

      compressed =
        messages
        |> Enum.map(fn message ->
          "#{message.role}: #{String.slice(Enum.join(texts(message), " "), 0, 500)}"
        end)
        |> Enum.join("\n\n")
        |> String.slice(0, 8000)

      content = compressed <> if(focus, do: "\n\nFocus especially on: #{focus}", else: "")

      request =
        Adapter.format_request(
          [%{role: "user", parts: [%Synapsis.Part.Text{content: content}]}],
          [],
          %{
            model: model,
            provider_type: type,
            provider_name: provider,
            endpoint: config[:base_url] || config["base_url"],
            max_tokens: 2048,
            system_prompt: Synapsis.Memory.Prompts.summarizer_system_prompt(),
            stream: true
          }
        )

      config = config |> Map.put(:type, type) |> Map.put_new(:provider_name, provider)

      with {:ok, handle} <- Adapter.stream(request, config, link: true) do
        try do
          with {:ok, text} <- collect(handle, [], 0), do: parse(text, kinds)
        after
          Adapter.cancel(handle)
          Process.unlink(handle.pid)
          Process.demonitor(handle.ref, [:flush])
        end
      end
    end
  end

  defp collect(%{pid: pid, ref: ref} = handle, chunks, bytes) do
    receive do
      {:provider_chunk, {:text_delta, text}} when is_binary(text) ->
        if byte_size(text) + bytes <= @output_limit,
          do: collect(handle, [text | chunks], bytes + byte_size(text)),
          else: {:error, :output_limit}

      {:provider_chunk, _} ->
        collect(handle, chunks, bytes)

      :provider_done ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:provider_error, _} ->
        {:error, :provider_failed}

      {:DOWN, ^ref, :process, ^pid, _} ->
        {:error, :provider_failed}

      {:EXIT, ^pid, _} ->
        {:error, :provider_failed}

      {^ref, _} ->
        collect(handle, chunks, bytes)
    after
      @timeout -> {:error, :provider_timeout}
    end
  end

  defp parse(text, kinds) do
    json =
      case Regex.run(~r/\[[\s\S]*\]/, text) do
        [array] -> array
        _ -> text
      end

    with {:ok, candidates} when is_list(candidates) <- Jason.decode(json),
         true <- length(candidates) <= 20 and Enum.all?(candidates, &candidate?/1) do
      {:ok,
       candidates
       |> Enum.filter(&(&1["kind"] in kinds))
       |> Enum.map(fn candidate ->
         %{
           kind: candidate["kind"],
           title: candidate["title"],
           summary: candidate["summary"] || candidate["title"],
           tags: candidate["tags"] || [],
           importance: candidate["importance"] || 0.6
         }
       end)}
    else
      _ -> {:error, :malformed_candidates}
    end
  end

  defp candidate?(candidate) when is_map(candidate) do
    candidate["kind"] in @kinds and text?(candidate["title"], 1024) and
      text?(Map.get(candidate, "summary", candidate["title"]), 4096) and
      is_list(Map.get(candidate, "tags", [])) and length(Map.get(candidate, "tags", [])) <= 10 and
      Enum.all?(Map.get(candidate, "tags", []), &text?(&1, 512)) and
      is_number(Map.get(candidate, "importance", 0.6)) and
      Map.get(candidate, "importance", 0.6) >= 0 and Map.get(candidate, "importance", 0.6) <= 1
  end

  defp candidate?(_), do: false

  defp heuristic(messages, focus, kinds) do
    text = messages |> Enum.flat_map(&texts/1) |> Enum.join("\n")

    focused =
      if focus && "fact" in kinds && String.length(text) > 50 do
        [
          %{
            kind: "fact",
            title: "Session summary: #{focus}",
            summary: String.slice(text, 0, 500),
            tags: [focus],
            importance: 0.7
          }
        ]
      else
        []
      end

    topics =
      text
      |> String.downcase()
      |> String.split(~r/\W+/, trim: true)
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(5)
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(String.length(&1) < 4))

    if length(messages) >= 5 and kinds != [] and topics != [] do
      focused ++
        [
          %{
            kind: hd(kinds),
            title: "Session topics: #{Enum.join(Enum.take(topics, 3), ", ")}",
            summary:
              "Session covered #{length(messages)} messages. Key topics: #{Enum.join(topics, ", ")}.",
            tags: topics,
            importance: 0.5
          }
        ]
    else
      focused
    end
  end

  defp bounded(opts, fun) do
    now = System.monotonic_time(:millisecond)
    deadline = Keyword.get(opts, :deadline, now + @timeout)

    cond do
      not is_integer(deadline) ->
        {:error, :invalid_input}

      deadline <= now ->
        {:error, :timeout}

      true ->
        deadline = min(deadline, now + @timeout)
        owner = self()
        reply = make_ref()
        {guardian, monitor} = spawn_monitor(fn -> guard(owner, reply, deadline, fun) end)

        receive do
          {^reply, result} ->
            receive do: ({:DOWN, ^monitor, :process, ^guardian, _} -> result)

          {:DOWN, ^monitor, :process, ^guardian, _} ->
            {:error, :worker_limit}
        end
    end
  end

  defp guard(owner, reply, deadline, fun) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    guardian = self()
    result_ref = make_ref()

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.flag(:trap_exit, true)

          result =
            if System.monotonic_time(:millisecond) < deadline,
              do: fun.(),
              else: {:error, :timeout}

          send(guardian, {result_ref, result})
        end,
        [:link, :monitor, {:max_heap_size, %{size: 2_000_000, kill: true, error_logger: false}}]
      )

    case await(worker, monitor, owner_monitor, result_ref, deadline, nil) do
      :owner_gone -> :ok
      result -> send(owner, {reply, result})
    end
  end

  defp await(worker, monitor, owner_monitor, result_ref, deadline, result) do
    receive do
      {^result_ref, value} ->
        await(worker, monitor, owner_monitor, result_ref, deadline, value)

      {:DOWN, ^monitor, :process, ^worker, _} ->
        result || {:error, :worker_limit}

      {:DOWN, ^owner_monitor, :process, _, _} ->
        stop(worker, monitor)
        :owner_gone

      {:EXIT, ^worker, _} ->
        await(worker, monitor, owner_monitor, result_ref, deadline, result)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        stop(worker, monitor)
        {:error, :timeout}
    end
  end

  defp stop(worker, monitor) do
    Process.exit(worker, :kill)
    receive do: ({:DOWN, ^monitor, :process, ^worker, _} -> :ok)
  end
end
