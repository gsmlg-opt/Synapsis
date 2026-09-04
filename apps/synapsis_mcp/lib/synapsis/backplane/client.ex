defmodule Synapsis.Backplane.Client do
  @moduledoc "Bounded client for Backplane capability discovery surfaces."

  alias Synapsis.Backplane.{Connection, Snapshot}

  @default_timeout 5_000
  @skill_limit 100
  @default_max_archive_bytes 4 * 1_024 * 1_024
  @default_max_expanded_bytes 8 * 1_024 * 1_024
  @default_max_skill_content_bytes 1 * 1_024 * 1_024
  @max_archive_entries 256

  @callback fetch_models(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_skills(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_skill(Connection.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback list_tools(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_snapshot(Connection.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  @optional_callbacks fetch_snapshot: 2

  def fetch_snapshot(%Connection{} = connection, opts \\ []) do
    surfaces = %{
      models: protect(fn -> fetch_models(connection, opts) end) |> redact_result(connection),
      skills: protect(fn -> fetch_skills(connection, opts) end) |> redact_result(connection),
      mcp_tools: protect(fn -> list_tools(connection, opts) end) |> redact_result(connection)
    }

    snapshot_opts =
      case Keyword.fetch(opts, :fetched_at) do
        {:ok, fetched_at} -> [fetched_at: fetched_at]
        :error -> []
      end

    Snapshot.normalize(connection, surfaces, snapshot_opts)
  end

  def fetch_models(%Connection{} = connection, opts \\ []) do
    with {:ok, %{"data" => models}} when is_list(models) <-
           get_json(connection.endpoint <> "/v1/models", auth_headers(connection), opts),
         true <- length(models) <= @skill_limit do
      {:ok, models}
    else
      false -> {:error, :models_limit_exceeded}
      {:ok, _body} -> {:error, :invalid_models_response}
      error -> error
    end
  end

  def list_skills(%Connection{} = connection, opts \\ []) do
    # WORKAROUND(upstream): gsmlg-opt/backplane#29
    url = connection.endpoint <> "/skills?limit=#{@skill_limit}"

    with {:ok, %{"data" => skills}} when is_list(skills) <-
           get_json(url, auth_headers(connection), opts),
         true <- length(skills) <= @skill_limit do
      {:ok, skills}
    else
      false -> {:error, :skills_limit_exceeded}
      {:ok, _body} -> {:error, :invalid_skills_response}
      error -> error
    end
  end

  def fetch_skill(%Connection{} = connection, slug, opts \\ []) when is_binary(slug) do
    encoded_slug = URI.encode(slug, &URI.char_unreserved?/1)

    with {:ok, detail} when is_map(detail) <-
           get_json(
             connection.endpoint <> "/skills/" <> encoded_slug,
             auth_headers(connection),
             opts
           ),
         {:ok, detail} <- maybe_load_skill_content(connection, encoded_slug, detail, opts) do
      {:ok, detail}
    else
      {:ok, _body} -> {:error, :invalid_skill_response}
      error -> error
    end
  end

  def list_tools(%Connection{} = connection, opts \\ []) do
    url = connection.endpoint <> "/mcp"
    auth_headers = auth_headers(connection)

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "synapsis", "version" => "0.1.0"}
      }
    }

    initialized = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    with {:ok, response} <- post_json(url, initialize, auth_headers, opts),
         :ok <- mcp_result(response.body),
         session_headers when session_headers != [] <- session_header(response),
         {:ok, _initialized_response} <-
           post_json(url, initialized, auth_headers ++ session_headers, opts),
         {:ok, listed} <-
           post_json(
             url,
             %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}},
             auth_headers ++ session_headers,
             opts
           ),
         {:ok, tools} <- tools_result(listed.body) do
      {:ok, tools}
    else
      [] -> {:error, :missing_mcp_session_id}
      error -> error
    end
  end

  defp fetch_skills(connection, opts) do
    with {:ok, skills} <- list_skills(connection, opts) do
      Enum.reduce_while(skills, {:ok, []}, fn summary, {:ok, details} ->
        case Map.get(summary, "slug") do
          slug when is_binary(slug) ->
            case fetch_skill(connection, slug, opts) do
              {:ok, detail} -> {:cont, {:ok, [Map.merge(summary, detail) | details]}}
              {:error, reason} -> {:halt, {:error, {:skill_detail, slug, reason}}}
            end

          _invalid ->
            {:halt, {:error, :invalid_skill_list}}
        end
      end)
      |> case do
        {:ok, details} -> {:ok, Enum.reverse(details)}
        error -> error
      end
    end
  end

  defp maybe_load_skill_content(_connection, _slug, %{"content" => content} = detail, opts)
       when is_binary(content) do
    if byte_size(content) <=
         option(opts, :max_skill_content_bytes, @default_max_skill_content_bytes) do
      {:ok, detail}
    else
      {:error, :skill_content_too_large}
    end
  end

  defp maybe_load_skill_content(connection, slug, %{"source_kind" => "archive"} = detail, opts) do
    with {:ok, archive} <-
           get_binary(
             connection.endpoint <> "/skills/" <> slug <> "/archive",
             auth_headers(connection),
             option(opts, :max_archive_bytes, @default_max_archive_bytes),
             opts
           ),
         {:ok, content} <- extract_skill_md(archive, opts) do
      {:ok, Map.put(detail, "content", content)}
    end
  end

  defp maybe_load_skill_content(_connection, _slug, %{"source_kind" => "generated"}, _opts),
    do: {:error, :missing_generated_skill_content}

  defp maybe_load_skill_content(connection, slug, %{"files" => files} = detail, opts)
       when is_list(files),
       do:
         maybe_load_skill_content(
           connection,
           slug,
           Map.put(detail, "source_kind", "archive"),
           opts
         )

  defp maybe_load_skill_content(_connection, _slug, _detail, _opts),
    do: {:error, :missing_skill_content}

  defp get_json(url, headers, opts) do
    case Req.get(url, [headers: headers] ++ request_opts(opts)) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_binary(url, headers, max_bytes, opts) do
    into = fn {:data, data}, {request, response} ->
      body = response.body || ""

      if byte_size(body) + byte_size(data) <= max_bytes do
        {:cont, {request, %{response | body: body <> data}}}
      else
        response = Req.Response.put_private(response, :synapsis_backplane_body_limit, true)
        {:halt, {request, response}}
      end
    end

    case Req.get(url, [headers: headers, into: into] ++ request_opts(opts)) do
      {:ok, %Req.Response{} = response} -> binary_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp binary_response(response) do
    cond do
      Req.Response.get_private(response, :synapsis_backplane_body_limit, false) ->
        {:error, :archive_too_large}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      not is_binary(response.body) ->
        {:error, :invalid_archive_response}

      true ->
        {:ok, response.body}
    end
  end

  defp post_json(url, body, headers, opts) do
    request_opts = [json: body, headers: headers] ++ request_opts(opts)

    case Req.post(url, request_opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_opts(opts) do
    timeout = option(opts, :timeout, @default_timeout)
    [receive_timeout: timeout, connect_options: [timeout: timeout], retry: false]
  end

  defp extract_skill_md(archive, opts) when is_binary(archive) do
    max_expanded = option(opts, :max_expanded_bytes, @default_max_expanded_bytes)
    max_content = option(opts, :max_skill_content_bytes, @default_max_skill_content_bytes)

    with {:ok, tar} <- decompress_archive(archive, max_expanded),
         {:ok, entries} <- parse_tar(tar, max_expanded),
         :ok <- validate_archive_entries(entries),
         [{_path, content}] <- Enum.filter(entries, &(Path.basename(elem(&1, 0)) == "SKILL.md")),
         true <- byte_size(content) <= max_content do
      {:ok, content}
    else
      [] -> {:error, :skill_md_not_found}
      [_first, _second | _rest] -> {:error, :multiple_skill_md_files}
      false -> {:error, :skill_content_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp decompress_archive(<<0x1F, 0x8B, _rest::binary>> = archive, max_bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 16 + 15)

      case collect_inflated(z, archive, max_bytes, 0, []) do
        {:ok, chunks} ->
          :ok = :zlib.inflateEnd(z)
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

        {:error, _reason} = error ->
          error
      end
    rescue
      ErlangError -> {:error, :invalid_archive}
    after
      :zlib.close(z)
    end
  end

  defp decompress_archive(archive, max_bytes) when byte_size(archive) <= max_bytes,
    do: {:ok, archive}

  defp decompress_archive(_archive, _max_bytes), do: {:error, :archive_expanded_too_large}

  defp collect_inflated(z, input, max_bytes, total_size, chunks) do
    case :zlib.safeInflate(z, input) do
      {:finished, output} ->
        append_inflated(output, max_bytes, total_size, chunks)

      {:continue, output} ->
        output_size = :erlang.iolist_size(output)

        if output_size == 0 do
          {:error, :invalid_archive}
        else
          case append_inflated(output, max_bytes, total_size, chunks) do
            {:ok, next_chunks} ->
              collect_inflated(z, <<>>, max_bytes, total_size + output_size, next_chunks)

            {:error, _reason} = error ->
              error
          end
        end
    end
  end

  defp append_inflated(output, max_bytes, total_size, chunks) do
    if total_size + :erlang.iolist_size(output) <= max_bytes,
      do: {:ok, [output | chunks]},
      else: {:error, :archive_expanded_too_large}
  end

  defp parse_tar(tar, max_bytes), do: parse_tar(tar, max_bytes, 0, 0, [])

  defp parse_tar(<<>>, _max_bytes, _total, _entry_count, entries),
    do: {:ok, Enum.reverse(entries)}

  defp parse_tar(<<header::binary-size(512), rest::binary>>, max_bytes, total, count, entries) do
    if zero_block?(header) do
      {:ok, Enum.reverse(entries)}
    else
      with :ok <- validate_tar_checksum(header),
           {:ok, name} <- tar_name(header),
           {:ok, size} <- tar_size(header),
           {:ok, type} <- tar_entry_type(header, size),
           :ok <- validate_entry_count(count),
           true <- total + size <= max_bytes,
           padded_size <- div(size + 511, 512) * 512,
           true <- byte_size(rest) >= padded_size,
           <<content::binary-size(size), _padding::binary-size(padded_size - size), tail::binary>> <-
             rest do
        entries = if type == :regular, do: [{name, content} | entries], else: entries
        parse_tar(tail, max_bytes, total + size, count + 1, entries)
      else
        false -> {:error, :archive_expanded_too_large}
        {:error, _reason} = error -> error
        _invalid -> {:error, :invalid_archive}
      end
    end
  end

  defp parse_tar(_invalid, _max_bytes, _total, _count, _entries),
    do: {:error, :invalid_archive}

  defp validate_entry_count(count) when count < @max_archive_entries, do: :ok
  defp validate_entry_count(_count), do: {:error, :archive_entry_limit_exceeded}

  defp validate_tar_checksum(header) do
    stored = header |> binary_part(148, 8) |> c_string() |> String.trim()
    checksum_header = replace_binary_part(header, 148, 8, "        ")
    calculated = checksum_header |> :binary.bin_to_list() |> Enum.sum()

    case Integer.parse(stored, 8) do
      {^calculated, ""} -> :ok
      _invalid -> {:error, :invalid_archive}
    end
  end

  defp tar_name(header) do
    name = header |> binary_part(0, 100) |> c_string()
    prefix = header |> binary_part(345, 155) |> c_string()
    path = if prefix == "", do: name, else: prefix <> "/" <> name
    segments = String.split(path, "/", trim: false)

    cond do
      path == "" -> {:error, :invalid_archive_path}
      Path.type(path) != :relative -> {:error, :unsafe_archive_path}
      String.contains?(path, "\\") -> {:error, :unsafe_archive_path}
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :unsafe_archive_path}
      Enum.any?(segments, &Regex.match?(~r/^[A-Za-z]:/, &1)) -> {:error, :unsafe_archive_path}
      Enum.any?(segments, &Regex.match?(~r/%2e/i, &1)) -> {:error, :unsafe_archive_path}
      true -> {:ok, path}
    end
  end

  defp tar_size(header) do
    size = header |> binary_part(124, 12) |> c_string() |> String.trim()

    case Integer.parse(size, 8) do
      {value, ""} when value >= 0 -> {:ok, value}
      _invalid -> {:error, :invalid_archive}
    end
  end

  defp tar_entry_type(header, _size) when binary_part(header, 156, 1) in [<<0>>, "0"],
    do: {:ok, :regular}

  defp tar_entry_type(header, 0) when binary_part(header, 156, 1) == "5",
    do: {:ok, :directory}

  defp tar_entry_type(_header, _size), do: {:error, :unsafe_archive_entry}

  defp validate_archive_entries(entries) do
    if Enum.all?(entries, fn {path, content} ->
         is_binary(path) and is_binary(content) and byte_size(path) <= 255
       end),
       do: :ok,
       else: {:error, :invalid_archive}
  end

  defp zero_block?(header), do: header == :binary.copy(<<0>>, 512)

  defp c_string(binary) do
    case :binary.match(binary, <<0>>) do
      {index, 1} -> binary_part(binary, 0, index)
      :nomatch -> binary
    end
  end

  defp replace_binary_part(binary, offset, length, replacement) do
    <<prefix::binary-size(offset), _old::binary-size(length), suffix::binary>> = binary
    prefix <> replacement <> suffix
  end

  defp mcp_result(%{"result" => _result}), do: :ok
  defp mcp_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp mcp_result(_body), do: {:error, :invalid_initialize_response}

  defp tools_result(%{"result" => %{"tools" => tools}}) when is_list(tools), do: {:ok, tools}
  defp tools_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp tools_result(_body), do: {:error, :invalid_tools_response}

  defp session_header(response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [session_id | _] when session_id != "" -> [{"mcp-session-id", session_id}]
      _missing -> []
    end
  end

  defp auth_headers(%Connection{credential: credential}) when is_binary(credential) do
    if String.trim(credential) == "", do: [], else: [{"authorization", "Bearer " <> credential}]
  end

  defp auth_headers(_connection), do: []

  defp option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp protect(fun) do
    fun.()
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp redact_result({:error, reason}, %Connection{credential: credential})
       when is_binary(credential) and credential != "" do
    {:error, redact_term(reason, credential)}
  end

  defp redact_result(result, _connection), do: result

  defp redact_term(value, credential) when is_binary(value),
    do: String.replace(value, credential, "[REDACTED]")

  defp redact_term(value, credential) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, redact_term(item, credential)} end)

  defp redact_term(value, credential) when is_list(value),
    do: Enum.map(value, &redact_term(&1, credential))

  defp redact_term(value, credential) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&redact_term(&1, credential)) |> List.to_tuple()
  end

  defp redact_term(value, _credential), do: value
end
