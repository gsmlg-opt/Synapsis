defmodule Synapsis.SessionDirectory.Projection.PortSession do
  @moduledoc """
  One invocation's bounded, reusable pure projection child.

  The invoking effect task owns the Port; there is no registry or retained
  runtime. Startup, both optional waves, and normal close share one absolute
  deadline. Success requires the worker-closed receipt and actual Node exit 0.
  Port release on an error is resource cleanup, never completion evidence.
  """

  @reference "488631c18fae7cc541ba8fc8beff6cbb0438787b"
  @input_limit 8 * 1024 * 1024
  @output_limit 1024 * 1024
  @chunk_size 65_536
  @history_wire_limit 65_536
  @history_transfer_limit 8 * 1024 * 1024
  @history_raw_chunk 32_768

  def run(node, deadline, fun) do
    with {:ok, session} <- open(node, deadline) do
      try do
        result = invoke(session, fun)

        case close(session) do
          :ok -> result
          {:error, _} -> {:error, :cleanup_unconfirmed}
        end
      after
        release(session)
      end
    end
  end

  defp invoke(session, fun) do
    with {:ok, ready, _bytes} <- frame(session),
         true <- ready == %{"type" => "ready", "protocol" => 1, "referenceCommit" => @reference} do
      fun.(session)
    else
      false -> {:error, :invalid_projection}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_projection}
  catch
    _, _ -> {:error, :invalid_projection}
  end

  def project(%{owner: owner} = session, rows, options) when owner == self() do
    id = Integer.to_string(session.sequence + 1)
    request = %{type: "project", protocol: 1, id: id, rows: rows, options: options}

    with {:ok, body} <- Jason.encode(request),
         true <- session.input_bytes + byte_size(body) + 128 <= @input_limit,
         :ok <- write(session, body <> "\n"),
         {:ok, envelope, bytes} <- frame(session),
         true <- session.output_bytes + bytes <= @output_limit,
         %{
           "type" => "result",
           "protocol" => 1,
           "id" => ^id,
           "referenceCommit" => @reference,
           "runtime" => %{
             "engine" => "node-worker",
             "heapLimitMb" => 128,
             "workerExitObserved" => false
           },
           "result" => result
         } <- envelope,
         true <-
           is_list(result) and length(result) == length(rows) and Enum.all?(result, &valid_row?/1) do
      {:ok, result,
       %{
         session
         | sequence: session.sequence + 1,
           input_bytes: session.input_bytes + byte_size(body) + 1,
           output_bytes: session.output_bytes + bytes
       }}
    else
      false -> {:error, :invalid_projection}
      {:error, _} = error -> error
      _ -> {:error, :invalid_projection}
    end
  end

  # History has its own per-transfer admission and framing. It neither consumes
  # a title/preview wave nor changes the legacy input/output counters.
  def history(%{owner: owner} = session, start, reader)
      when owner == self() and is_function(reader, 1) do
    with :ok <- send_history(session, start),
         {:ok, candidate} <- history_result(session, start, reader) do
      {:ok, candidate, %{session | history_sequence: session.history_sequence + 1}}
    end
  end

  defp history_result(session, start, reader) do
    id = start["id"]
    slot = start["target"]["slot"]

    with {:ok, envelope} <- receive_history(session) do
      case envelope do
        %{
          "type" => "history_read",
          "protocol" => 1,
          "historyProtocol" => 1,
          "id" => ^id,
          "slot" => ^slot,
          "readId" => read_id
        }
        when is_binary(read_id) and byte_size(read_id) > 0 ->
          case reader.(envelope) do
            {:ok, reply} ->
              with true <-
                     reply["id"] == id and reply["slot"] == slot and reply["readId"] == read_id,
                   :ok <- send_history(session, reply) do
                history_result(session, start, reader)
              else
                false -> {:error, :invalid_projection}
                error -> error
              end

            {:error, reason} = error ->
              _ =
                history_control(session, %{
                  "type" => "history_error",
                  "id" => id,
                  "readId" => read_id,
                  "reason" => to_string(reason)
                })

              error
          end

        %{
          "type" => "history_result",
          "protocol" => 1,
          "historyProtocol" => 1,
          "id" => ^id,
          "slot" => ^slot,
          "referenceCommit" => @reference,
          "candidate" => candidate,
          "runtime" => %{
            "engine" => "node-worker",
            "heapLimitMb" => 128,
            "workerExitObserved" => false
          }
        } ->
          decode_candidate(candidate, Map.get(start, "mode", "inline"))

        %{
          "type" => "history_error",
          "protocol" => 1,
          "historyProtocol" => 1,
          "id" => ^id,
          "reason" => reason
        } ->
          history_error(reason)

        _ ->
          {:error, :invalid_projection}
      end
    end
  end

  defp send_history(session, logical) do
    with {:ok, body} <- Jason.encode(logical) do
      cond do
        byte_size(body) > @history_transfer_limit ->
          {:error, :history_reader_admission}

        byte_size(body) + 1 <= @history_wire_limit ->
          write(session, body <> "\n")

        true ->
          transfer_id = "x#{System.unique_integer([:positive, :monotonic])}"

          with :ok <-
                 history_control(session, %{
                   "type" => "history_transfer_start",
                   "transferId" => transfer_id,
                   "logicalType" => logical["type"],
                   "bytes" => byte_size(body)
                 }),
               :ok <- transfer_ack(session, transfer_id, 0, false),
               {:ok, count} <- send_chunks(session, transfer_id, body, 0),
               :ok <-
                 history_control(session, %{
                   "type" => "history_transfer_end",
                   "transferId" => transfer_id
                 }),
               :ok <- transfer_ack(session, transfer_id, count, true) do
            :ok
          end
      end
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp send_chunks(_session, _transfer_id, <<>>, sequence), do: {:ok, sequence}

  defp send_chunks(session, transfer_id, body, sequence) do
    size = min(byte_size(body), @history_raw_chunk)
    <<chunk::binary-size(size), rest::binary>> = body

    with :ok <-
           history_control(session, %{
             "type" => "history_transfer_chunk",
             "transferId" => transfer_id,
             "sequence" => sequence,
             "data" => Base.encode64(chunk)
           }),
         :ok <- transfer_ack(session, transfer_id, sequence + 1, false) do
      send_chunks(session, transfer_id, rest, sequence + 1)
    end
  end

  defp transfer_ack(session, transfer_id, sequence, complete?) do
    with {:ok, frame, _bytes} <- history_frame(session) do
      expected = %{
        "type" => "history_transfer_ack",
        "protocol" => 1,
        "historyProtocol" => 1,
        "transferId" => transfer_id,
        "nextSequence" => sequence
      }

      expected = if complete?, do: Map.put(expected, "complete", true), else: expected
      if frame == expected, do: :ok, else: {:error, :invalid_projection}
    end
  end

  defp receive_history(session) do
    with {:ok, envelope, _bytes} <- history_frame(session) do
      case envelope do
        %{
          "type" => "history_transfer_start",
          "protocol" => 1,
          "historyProtocol" => 1,
          "transferId" => transfer_id,
          "logicalType" => logical_type,
          "bytes" => bytes
        }
        when is_binary(transfer_id) and byte_size(transfer_id) > 0 and
               logical_type in ["history_start", "history_read_result", "history_result"] and
               is_integer(bytes) and bytes > 0 and bytes <= @history_transfer_limit ->
          with :ok <- send_ack(session, transfer_id, 0, false),
               {:ok, body} <- receive_chunks(session, transfer_id, bytes, 0, [], 0),
               {:ok, logical} <- Jason.decode(body),
               true <- logical["type"] == logical_type do
            {:ok, logical}
          else
            false -> {:error, :invalid_projection}
            {:error, reason} when is_atom(reason) -> {:error, reason}
            _ -> {:error, :invalid_projection}
          end

        %{"type" => "history_transfer_start"} ->
          {:error, :history_reader_admission}

        _ ->
          {:ok, envelope}
      end
    end
  end

  defp receive_chunks(session, transfer_id, total, sequence, chunks, size) do
    with {:ok, envelope, _bytes} <- history_frame(session) do
      case envelope do
        %{
          "type" => "history_transfer_chunk",
          "protocol" => 1,
          "historyProtocol" => 1,
          "transferId" => ^transfer_id,
          "sequence" => ^sequence,
          "data" => data
        }
        when is_binary(data) ->
          with {:ok, chunk} <- Base.decode64(data),
               true <-
                 byte_size(chunk) in 1..@history_raw_chunk and size + byte_size(chunk) <= total,
               :ok <- send_ack(session, transfer_id, sequence + 1, false) do
            receive_chunks(
              session,
              transfer_id,
              total,
              sequence + 1,
              [chunk | chunks],
              size + byte_size(chunk)
            )
          else
            _ -> {:error, :invalid_projection}
          end

        %{
          "type" => "history_transfer_end",
          "protocol" => 1,
          "historyProtocol" => 1,
          "transferId" => ^transfer_id
        }
        when size == total ->
          with :ok <- send_ack(session, transfer_id, sequence, true) do
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
          end

        _ ->
          {:error, :invalid_projection}
      end
    end
  end

  defp send_ack(session, transfer_id, sequence, complete?) do
    frame = %{
      "type" => "history_transfer_ack",
      "transferId" => transfer_id,
      "nextSequence" => sequence
    }

    history_control(session, if(complete?, do: Map.put(frame, "complete", true), else: frame))
  end

  defp history_control(session, frame) do
    frame = Map.merge(frame, %{"protocol" => 1, "historyProtocol" => 1})

    with {:ok, body} <- Jason.encode(frame),
         true <- byte_size(body) + 1 <= @history_wire_limit do
      write(session, body <> "\n")
    else
      false -> {:error, :history_reader_admission}
      error -> error
    end
  end

  defp decode_candidate(%{"mode" => "standalone", "text" => text, "page" => page}, "standalone")
       when is_binary(text) and is_map(page) do
    with true <- byte_size(text) <= 262_144,
         {:ok, decoded} <- Jason.decode(text),
         true <- decoded == page do
      {:ok, %{text: text, page: page}}
    else
      _ -> {:error, :invalid_projection}
    end
  end

  defp decode_candidate(candidate, "inline"), do: decode_candidate(candidate)
  defp decode_candidate(_, _), do: {:error, :invalid_projection}

  defp decode_candidate(%{"enriched" => enriched, "metadata" => metadata} = candidate) do
    with {:ok, enriched} <- decode_fragment(enriched),
         {:ok, metadata} <- decode_fragment(metadata),
         true <- Map.keys(candidate) -- ~w(messages enriched metadata) == [],
         true <-
           if(enriched.kind == "json",
             do: is_list(candidate["messages"]),
             else: not Map.has_key?(candidate, "messages")
           ) do
      result = %{enriched: enriched, metadata: metadata}

      {:ok,
       if(Map.has_key?(candidate, "messages"),
         do: Map.put(result, :messages, candidate["messages"]),
         else: result
       )}
    else
      false -> {:error, :invalid_projection}
      error -> error
    end
  end

  defp decode_candidate(_), do: {:error, :invalid_projection}

  defp decode_fragment(%{"kind" => "json", "json" => json, "utf8Bytes" => bytes})
       when is_binary(json) and is_integer(bytes) and bytes >= 0 and bytes <= 65_536 and
              byte_size(json) == bytes,
       do: {:ok, %{kind: "json", json: json, utf8_bytes: bytes}}

  defp decode_fragment(%{"kind" => "oversize", "utf8Bytes" => bytes})
       when is_integer(bytes) and bytes > 65_536,
       do: {:ok, %{kind: "oversize", utf8_bytes: bytes}}

  defp decode_fragment(_), do: {:error, :invalid_projection}

  # Keep helper/domain reasons bounded; no arbitrary string-to-atom conversion.
  defp history_error("history_reader_admission"), do: {:error, :history_reader_admission}
  defp history_error("timeout"), do: {:error, :timeout}
  defp history_error("payload_too_large"), do: {:error, :payload_too_large}
  defp history_error(_), do: {:error, :invalid_projection}

  defp open(node, deadline) do
    helper = Application.app_dir(:synapsis_core, "priv/session_directory/helper.mjs")

    cond do
      not is_binary(node) or Path.type(node) != :absolute ->
        {:error, :helper_unavailable}

      remaining(deadline) <= 0 ->
        {:error, :timeout}

      true ->
        port =
          Port.open({:spawn_executable, String.to_charlist(node)}, [
            :binary,
            :exit_status,
            :use_stdio,
            :eof,
            {:line, @chunk_size},
            args: [
              String.to_charlist(helper),
              ~c"--timeout-ms",
              Integer.to_charlist(remaining(deadline))
            ]
          ])

        {:ok,
         %{
           port: port,
           monitor: :erlang.monitor(:port, port),
           owner: self(),
           deadline: deadline,
           sequence: 0,
           history_sequence: 0,
           input_bytes: 0,
           output_bytes: 0
         }}
    end
  rescue
    _ -> {:error, :helper_unavailable}
  end

  defp close(session) do
    with :ok <- write(session, "{\"type\":\"close\"}\n"),
         {:ok,
          %{
            "type" => "closed",
            "protocol" => 1,
            "runtime" => %{
              "engine" => "node-worker",
              "heapLimitMb" => 128,
              "workerExitObserved" => true
            }
          }, _} <- frame(session),
         :ok <- await_exit(session) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_projection}
    end
  end

  defp write(session, body) do
    if remaining(session.deadline) <= 0 do
      {:error, :timeout}
    else
      if Port.command(session.port, body, [:nosuspend]) do
        :ok
      else
        receive do
        after
          min(5, remaining(session.deadline)) -> write(session, body)
        end
      end
    end
  rescue
    _ -> {:error, :helper_unavailable}
  end

  defp frame(session), do: frame(session, [], 0, @output_limit)
  defp history_frame(session), do: frame(session, [], 0, @history_wire_limit)

  defp frame(%{port: port, monitor: monitor} = session, chunks, size, limit) do
    receive do
      {^port, {:data, {kind, chunk}}} when kind in [:eol, :noeol] ->
        bytes = size + byte_size(chunk) + 1

        cond do
          bytes > limit ->
            {:error, :payload_too_large}

          kind == :noeol ->
            frame(session, [chunk | chunks], bytes - 1, limit)

          true ->
            text = [chunk | chunks] |> Enum.reverse() |> IO.iodata_to_binary()

            case Jason.decode(text) do
              {:ok, value} -> {:ok, value, bytes}
              _ -> {:error, :invalid_projection}
            end
        end

      {^port, {:exit_status, _}} ->
        {:error, :helper_unavailable}

      {^port, :eof} ->
        {:error, :helper_unavailable}

      {:DOWN, ^monitor, :port, ^port, :normal} ->
        frame(session, chunks, size, limit)

      {:DOWN, ^monitor, :port, ^port, _} ->
        {:error, :helper_unavailable}
    after
      remaining(session.deadline) -> {:error, :timeout}
    end
  end

  defp await_exit(%{port: port, monitor: monitor} = session) do
    receive do
      {^port, {:exit_status, 0}} ->
        if remaining(session.deadline) > 0, do: :ok, else: {:error, :timeout}

      {^port, {:exit_status, _}} ->
        {:error, :helper_unavailable}

      {^port, :eof} ->
        await_exit(session)

      {:DOWN, ^monitor, :port, ^port, :normal} ->
        await_exit(session)

      {:DOWN, ^monitor, :port, ^port, _} ->
        {:error, :helper_unavailable}
    after
      remaining(session.deadline) -> {:error, :timeout}
    end
  end

  defp valid_row?(%{"needsHead" => head, "needsTail" => tail} = row) do
    is_boolean(head) and is_boolean(tail) and
      Map.keys(row) -- ~w(needsHead needsTail derivedTitle lastMessagePreview) == [] and
      Enum.all?(~w(derivedTitle lastMessagePreview), fn key ->
        not Map.has_key?(row, key) or (is_binary(row[key]) and String.valid?(row[key]))
      end)
  end

  defp valid_row?(_), do: false

  defp release(session) do
    :erlang.demonitor(session.monitor, [:flush])
    Port.close(session.port)
  rescue
    ArgumentError -> :ok
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
