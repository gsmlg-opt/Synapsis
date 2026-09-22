defmodule Synapsis.Backplane.Client do
  @moduledoc "Bounded client for Backplane capability discovery surfaces."

  alias Synapsis.Backplane.{Connection, Snapshot}
  alias Elixir.Backplane.SkillProtocol.{Descriptor, Source.Backplane}
  alias Elixir.Backplane.SkillProtocol.Client, as: SkillProtocolClient

  @default_timeout 5_000
  @skill_limit 100
  @default_max_models_response_bytes 4 * 1_024 * 1_024
  @default_max_skills_response_bytes 2 * 1_024 * 1_024
  @default_max_skill_detail_response_bytes 2 * 1_024 * 1_024
  @default_max_mcp_response_bytes 4 * 1_024 * 1_024
  @default_max_archive_bytes 4 * 1_024 * 1_024
  @default_max_expanded_bytes 8 * 1_024 * 1_024
  @default_max_skill_content_bytes 1 * 1_024 * 1_024
  @max_archive_files 500
  @max_archive_entries 1_000
  @mcp_protocol_version "2025-03-26"
  @mcp_accept "application/json, text/event-stream"
  @default_max_mcp_pages 100
  @max_mcp_pages 100
  @max_mcp_cursor_bytes 4_096
  @default_max_skill_protocol_pages 100

  @callback fetch_models(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_skills(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_skill(Connection.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback list_tools(Connection.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback fetch_snapshot(Connection.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  @optional_callbacks fetch_snapshot: 2

  def fetch_snapshot(%Connection{} = connection, opts \\ []) do
    mcp_discovery =
      protect(fn -> discover_mcp(connection, opts, true) end)
      |> redact_result(connection)

    surfaces = %{
      models: protect(fn -> fetch_models(connection, opts) end) |> redact_result(connection),
      skills: protect(fn -> fetch_skills(connection, opts) end) |> redact_result(connection),
      mcp_tools: mcp_tools_surface(mcp_discovery)
    }

    surfaces = maybe_put_other_capabilities(surfaces, mcp_discovery)

    snapshot_opts =
      case Keyword.fetch(opts, :fetched_at) do
        {:ok, fetched_at} -> [fetched_at: fetched_at]
        :error -> []
      end

    Snapshot.normalize(connection, surfaces, snapshot_opts)
  end

  def fetch_models(%Connection{} = connection, opts \\ []) do
    with {:ok, %{"data" => models}} when is_list(models) <-
           get_json(
             connection.endpoint <> "/v1/models",
             auth_headers(connection),
             response_bound(
               opts,
               :max_models_response_bytes,
               @default_max_models_response_bytes,
               :models_response_too_large
             ),
             opts
           ) do
      {:ok, models}
    else
      {:ok, _body} -> {:error, :invalid_models_response}
      error -> error
    end
  end

  def list_skills(%Connection{} = connection, opts \\ []) do
    # WORKAROUND(upstream): gsmlg-opt/backplane#29
    url = connection.endpoint <> "/skills?limit=#{@skill_limit}"

    with {:ok, %{"data" => skills}} when is_list(skills) <-
           get_json(
             url,
             auth_headers(connection),
             response_bound(
               opts,
               :max_skills_response_bytes,
               @default_max_skills_response_bytes,
               :skills_response_too_large
             ),
             opts
           ),
         true <- length(skills) <= @skill_limit do
      {:ok, skills}
    else
      false -> {:error, :skills_limit_exceeded}
      {:ok, _body} -> {:error, :invalid_skills_response}
      error -> error
    end
  end

  @doc "List exact Skill Protocol v1 descriptors with bounded cursor pagination."
  def list_protocol_skills(%Connection{} = connection, opts \\ []) do
    max_skills = option(opts, :max_skills, @skill_limit)
    max_pages = option(opts, :max_skill_pages, @default_max_skill_protocol_pages)

    with true <- is_integer(max_skills) and max_skills > 0 and max_skills <= @skill_limit,
         true <-
           is_integer(max_pages) and max_pages > 0 and
             max_pages <= @default_max_skill_protocol_pages,
         {:ok, client} <- skill_protocol_client(connection, opts) do
      source = Backplane.new!(client)
      paginate_protocol_skills(source, nil, max_skills, max_pages, MapSet.new(), [])
    else
      false -> {:error, :invalid_skill_protocol_limit}
      {:error, reason} -> {:error, skill_protocol_error(reason)}
    end
  end

  def fetch_skill(%Connection{} = connection, slug, opts \\ []) when is_binary(slug) do
    encoded_slug = URI.encode(slug, &URI.char_unreserved?/1)

    with {:ok, detail} when is_map(detail) <-
           get_json(
             connection.endpoint <> "/skills/" <> encoded_slug,
             auth_headers(connection),
             response_bound(
               opts,
               :max_skill_detail_response_bytes,
               @default_max_skill_detail_response_bytes,
               :skill_detail_response_too_large
             ),
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
    with {:ok, tools, _other_capabilities} <- discover_mcp(connection, opts, false) do
      {:ok, tools}
    end
  end

  defp discover_mcp(%Connection{} = connection, opts, discover_optional?) do
    url = connection.endpoint <> "/mcp"
    auth_headers = auth_headers(connection)

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @mcp_protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "synapsis", "version" => "0.1.0"}
      }
    }

    initialized = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    response_bound =
      response_bound(
        opts,
        :max_mcp_response_bytes,
        @default_max_mcp_response_bytes,
        :mcp_response_too_large
      )

    with {:ok, response} <-
           post_json(url, initialize, mcp_accept_headers(auth_headers), response_bound, opts),
         {:ok, capabilities, protocol_version} <- mcp_capabilities(response.body),
         session_headers when session_headers != [] <- session_header(response),
         request_headers <-
           mcp_session_headers(auth_headers, session_headers, protocol_version),
         {:ok, _initialized_response} <-
           post_json(url, initialized, request_headers, response_bound, opts),
         {:ok, tools} <-
           list_mcp_catalog(
             url,
             request_headers,
             response_bound,
             opts,
             "tools/list",
             2,
             &tools_result/1
           ) do
      other_capabilities =
        if discover_optional? do
          discover_optional_capabilities(
            url,
            request_headers,
            response_bound,
            opts,
            capabilities
          )
        else
          {:ok, []}
        end

      {:ok, tools, other_capabilities}
    else
      [] -> {:error, :missing_mcp_session_id}
      error -> error
    end
  end

  defp mcp_tools_surface({:ok, tools, _other_capabilities}), do: {:ok, tools}
  defp mcp_tools_surface({:error, _reason} = error), do: error

  defp maybe_put_other_capabilities(surfaces, {:ok, _tools, other_capabilities}),
    do: Map.put(surfaces, :other_capabilities, other_capabilities)

  defp maybe_put_other_capabilities(surfaces, {:error, _reason}), do: surfaces

  defp discover_optional_capabilities(url, headers, response_bound, opts, capabilities) do
    results =
      []
      |> maybe_discover_prompts(url, headers, response_bound, opts, capabilities)
      |> maybe_discover_resources(url, headers, response_bound, opts, capabilities)

    {entries, errors} =
      Enum.reduce(results, {[], %{}}, fn
        {_surface, {:ok, discovered}}, {entries, errors} ->
          {entries ++ discovered, errors}

        {surface, {:error, reason}}, {entries, errors} ->
          {entries, Map.put(errors, surface, reason)}
      end)

    if map_size(errors) == 0,
      do: {:ok, entries},
      else: {:incomplete, entries, errors}
  end

  defp maybe_discover_prompts(results, url, headers, response_bound, opts, capabilities) do
    if advertised?(capabilities, "prompts") do
      result =
        list_mcp_catalog(
          url,
          headers,
          response_bound,
          opts,
          "prompts/list",
          3,
          &prompts_result/1
        )

      results ++ [{:prompts, result}]
    else
      results
    end
  end

  defp maybe_discover_resources(results, url, headers, response_bound, opts, capabilities) do
    if advertised?(capabilities, "resources") do
      resources =
        list_mcp_catalog(
          url,
          headers,
          response_bound,
          opts,
          "resources/list",
          4,
          &resources_result/1
        )

      templates =
        list_mcp_catalog(
          url,
          headers,
          response_bound,
          opts,
          "resources/templates/list",
          5,
          &resource_templates_result/1
        )

      results ++ [{:resources, resources}, {:resource_templates, templates}]
    else
      results
    end
  end

  defp advertised?(capabilities, name),
    do: is_map(capabilities) and Map.has_key?(capabilities, name)

  defp list_mcp_catalog(url, headers, response_bound, opts, method, request_id, parser) do
    do_list_mcp_catalog(
      url,
      headers,
      response_bound,
      opts,
      method,
      request_id,
      parser,
      nil,
      MapSet.new(),
      [],
      1,
      mcp_page_limit(opts)
    )
  end

  defp do_list_mcp_catalog(
         _url,
         _headers,
         _response_bound,
         _opts,
         _method,
         _request_id,
         _parser,
         _cursor,
         _seen_cursors,
         _pages,
         page,
         page_limit
       )
       when page > page_limit,
       do: {:error, :mcp_page_limit_exceeded}

  defp do_list_mcp_catalog(
         url,
         headers,
         response_bound,
         opts,
         method,
         request_id,
         parser,
         cursor,
         seen_cursors,
         pages,
         page,
         page_limit
       ) do
    params = if is_binary(cursor), do: %{"cursor" => cursor}, else: %{}
    request = %{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}

    with {:ok, response} <- post_json(url, request, headers, response_bound, opts),
         {:ok, entries, next_cursor} <- parser.(response.body),
         {:ok, seen_cursors} <- remember_cursor(next_cursor, seen_cursors) do
      pages = [entries | pages]

      case next_cursor do
        nil ->
          {:ok, pages |> Enum.reverse() |> Enum.flat_map(& &1)}

        next_cursor ->
          do_list_mcp_catalog(
            url,
            headers,
            response_bound,
            opts,
            method,
            request_id,
            parser,
            next_cursor,
            seen_cursors,
            pages,
            page + 1,
            page_limit
          )
      end
    end
  end

  defp fetch_skills(connection, opts) do
    if legacy_skill_discovery?(connection) do
      fetch_legacy_skills(connection, opts)
    else
      case list_protocol_skills(connection, opts) do
        {:ok, skills, false} -> {:ok, skills}
        {:ok, skills, true} -> {:incomplete, skills, :skills_limit_reached}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_legacy_skills(connection, opts) do
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
        {:ok, details} when length(skills) == @skill_limit ->
          {:incomplete, Enum.reverse(details), :skills_limit_reached}

        {:ok, details} ->
          {:ok, Enum.reverse(details)}

        error ->
          error
      end
    end
  end

  defp legacy_skill_discovery?(connection) do
    Map.get(connection.connection_options || %{}, "skill_protocol") == "legacy"
  end

  defp skill_protocol_client(connection, opts) do
    timeout = option(opts, :timeout, @default_timeout)

    SkillProtocolClient.new(
      endpoint: connection.endpoint,
      source_id: connection.id,
      access_context_id: "synapsis-sync:#{connection.id}",
      credential_supplier: fn -> connection.credential end,
      overall_timeout_ms: timeout,
      max_json_bytes:
        option(opts, :max_skills_response_bytes, @default_max_skills_response_bytes),
      max_artifact_bytes: option(opts, :max_archive_bytes, @default_max_archive_bytes),
      max_attempts: 2,
      cancelled?: cancellation(opts)
    )
  end

  defp paginate_protocol_skills(_source, _cursor, remaining, _pages, _seen, acc)
       when remaining == 0,
       do: {:ok, Enum.reverse(acc), true}

  defp paginate_protocol_skills(_source, _cursor, _remaining, 0, _seen, _acc),
    do: {:error, :skill_protocol_page_limit_exceeded}

  defp paginate_protocol_skills(source, cursor, remaining, pages, seen, acc) do
    opts = [limit: min(remaining, @skill_limit), cursor: cursor]

    case Backplane.catalog(source, opts) do
      {:ok, %{data: descriptors, next_cursor: next_cursor}} when is_list(descriptors) ->
        with true <- length(descriptors) <= remaining,
             :ok <- validate_protocol_cursor(next_cursor, seen) do
          mapped = Enum.map(descriptors, &protocol_skill_map/1)
          next_acc = Enum.reverse(mapped, acc)

          if is_nil(next_cursor) do
            {:ok, Enum.reverse(next_acc), false}
          else
            paginate_protocol_skills(
              source,
              next_cursor,
              remaining - length(descriptors),
              pages - 1,
              MapSet.put(seen, next_cursor),
              next_acc
            )
          end
        else
          false -> {:error, :skills_limit_exceeded}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, skill_protocol_error(reason)}

      _invalid ->
        {:error, :invalid_skills_response}
    end
  end

  defp validate_protocol_cursor(nil, _seen), do: :ok

  defp validate_protocol_cursor(cursor, seen) when is_binary(cursor) do
    cond do
      byte_size(cursor) > @max_mcp_cursor_bytes -> {:error, :skill_protocol_cursor_too_large}
      MapSet.member?(seen, cursor) -> {:error, :skill_protocol_cursor_cycle}
      true -> :ok
    end
  end

  defp validate_protocol_cursor(_cursor, _seen), do: {:error, :invalid_skills_response}

  defp protocol_skill_map(%Descriptor{} = descriptor) do
    %{
      "id" => descriptor.ref.skill_id,
      "slug" => descriptor.ref.skill_id,
      "name" => descriptor.name,
      "description" => descriptor.description,
      "revision" => descriptor.revision,
      "artifact_digest" => descriptor.artifact_digest,
      "publication_status" => to_string(descriptor.publication_status),
      "enabled" => descriptor.publication_status == :ready,
      "content_available" =>
        is_binary(descriptor.revision) and is_binary(descriptor.artifact_digest)
    }
  end

  defp skill_protocol_error(%{code: code}) when is_atom(code), do: {:skill_protocol, code}
  defp skill_protocol_error(reason), do: reason

  defp cancellation(opts) do
    case Keyword.get(opts, :cancelled?) do
      fun when is_function(fun, 0) -> fun
      _ -> fn -> false end
    end
  end

  defp maybe_load_skill_content(
         _connection,
         _slug,
         %{"source_kind" => "generated", "content" => content} = detail,
         opts
       )
       when is_binary(content) do
    if byte_size(content) <=
         option(opts, :max_skill_content_bytes, @default_max_skill_content_bytes) do
      {:ok, Map.put(detail, "content_available", true)}
    else
      {:error, :skill_content_too_large}
    end
  end

  defp maybe_load_skill_content(connection, slug, %{"source_kind" => "archive"} = detail, opts) do
    with {:ok, expected_hash} <- archive_content_hash(detail),
         {:ok, archive} <-
           get_binary(
             connection.endpoint <> "/skills/" <> slug <> "/archive",
             auth_headers(connection),
             option(opts, :max_archive_bytes, @default_max_archive_bytes),
             opts
           ),
         :ok <- verify_archive_content_hash(archive, expected_hash),
         {:ok, content} <- extract_skill_md(archive, opts) do
      {:ok, detail |> Map.put("content", content) |> Map.put("content_available", true)}
    end
  end

  defp maybe_load_skill_content(_connection, _slug, %{"source_kind" => "generated"}, _opts),
    do: {:error, :missing_generated_skill_content}

  # WORKAROUND(upstream): gsmlg-opt/backplane#30
  defp maybe_load_skill_content(
         _connection,
         slug,
         %{"source_kind" => source_kind} = detail,
         _opts
       )
       when source_kind in ["database", "github"] do
    {:ok,
     detail
     |> Map.put("content_available", false)
     |> Map.put("content_unavailable_reason", "source_kind_not_exportable")
     |> Map.put("content_reference", %{
       "slug" => slug,
       "source_kind" => source_kind,
       "upstream_issue" => "gsmlg-opt/backplane#30"
     })}
  end

  defp maybe_load_skill_content(_connection, _slug, %{"content" => content} = detail, opts)
       when is_binary(content) do
    if byte_size(content) <=
         option(opts, :max_skill_content_bytes, @default_max_skill_content_bytes) do
      {:ok, Map.put(detail, "content_available", true)}
    else
      {:error, :skill_content_too_large}
    end
  end

  defp maybe_load_skill_content(_connection, _slug, _detail, _opts),
    do: {:error, :missing_skill_content}

  defp archive_content_hash(%{"content_hash" => hash}) when is_binary(hash) do
    normalized = String.downcase(hash)

    if Regex.match?(~r/^[a-f0-9]{64}$/, normalized),
      do: {:ok, normalized},
      else: {:error, :invalid_archive_content_hash}
  end

  defp archive_content_hash(_detail), do: {:error, :missing_archive_content_hash}

  defp verify_archive_content_hash(archive, expected_hash) do
    actual_hash = archive |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    if actual_hash == expected_hash,
      do: :ok,
      else: {:error, :archive_content_hash_mismatch}
  end

  defp get_json(url, headers, response_bound, opts) do
    with {:ok, {_response, body}} <-
           request_bounded(:get, url, headers, nil, response_bound, opts),
         {:ok, decoded} <- decode_json(body) do
      {:ok, decoded}
    end
  end

  defp get_binary(url, headers, max_bytes, opts) do
    with {:ok, {_response, body}} <-
           request_bounded(
             :get,
             url,
             headers,
             nil,
             {max_bytes, :archive_too_large},
             opts
           ) do
      {:ok, body}
    end
  end

  defp post_json(url, body, headers, response_bound, opts) do
    with {:ok, {response, response_body}} <-
           request_bounded(:post, url, headers, body, response_bound, opts),
         {:ok, decoded} <- decode_optional_json(response_body) do
      {:ok, %{response | body: decoded}}
    end
  end

  defp request_bounded(method, url, headers, request_body, response_bound, opts) do
    request_opts =
      [
        method: method,
        url: url,
        headers: headers,
        raw: true,
        into: bounded_into(response_bound)
      ] ++ request_opts(opts)

    request_opts =
      if request_body == nil,
        do: request_opts,
        else: [{:json, request_body} | request_opts]

    case Req.request(request_opts) do
      {:ok, %Req.Response{} = response} -> bounded_response(response, response_bound)
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_into({max_bytes, _too_large_error}) do
    fn {:data, data}, {request, response} ->
      {size, chunks} =
        Req.Response.get_private(response, :synapsis_backplane_body, {0, []})

      next_size = size + byte_size(data)

      if next_size <= max_bytes do
        response =
          Req.Response.put_private(
            response,
            :synapsis_backplane_body,
            {next_size, [data | chunks]}
          )

        {:cont, {request, response}}
      else
        response = Req.Response.put_private(response, :synapsis_backplane_body_limit, true)
        {:halt, {request, response}}
      end
    end
  end

  defp bounded_response(response, {_max_bytes, too_large_error}) do
    cond do
      Req.Response.get_private(response, :synapsis_backplane_body_limit, false) ->
        {:error, too_large_error}

      response.status not in 200..299 ->
        {:error, {:http_status, response.status}}

      true ->
        {_size, chunks} =
          Req.Response.get_private(response, :synapsis_backplane_body, {0, []})

        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        response = Req.Response.put_private(response, :synapsis_backplane_body, {0, []})
        {:ok, {response, body}}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json_response}
    end
  end

  defp decode_optional_json(""), do: {:ok, ""}
  defp decode_optional_json(body), do: decode_json(body)

  defp request_opts(opts) do
    timeout = option(opts, :timeout, @default_timeout)

    [
      receive_timeout: timeout,
      request_timeout: timeout,
      connect_options: [timeout: timeout],
      retry: false
    ]
  end

  defp response_bound(opts, key, default, too_large_error) do
    {option(opts, key, default), too_large_error}
  end

  defp extract_skill_md(archive, opts) when is_binary(archive) do
    max_expanded = option(opts, :max_expanded_bytes, @default_max_expanded_bytes)
    max_content = option(opts, :max_skill_content_bytes, @default_max_skill_content_bytes)

    with {:ok, tar} <- decompress_archive(archive, max_expanded),
         {:ok, table_entries} <- archive_table(tar),
         {:ok, entries} <- validate_archive_entries(table_entries, max_expanded),
         [skill_entry] <- Enum.filter(entries, &skill_md_entry?/1),
         true <- skill_entry.size <= max_content,
         {:ok, content} <- extract_archive_entry(tar, skill_entry) do
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

  defp archive_table(tar) do
    case :erl_tar.table({:binary, tar}, [:verbose]) do
      {:ok, entries} -> {:ok, entries}
      {:error, _reason} -> {:error, :invalid_archive}
    end
  catch
    _kind, _reason -> {:error, :invalid_archive}
  end

  defp validate_archive_entries(entries, max_bytes) when is_list(entries) do
    with :ok <- validate_archive_entry_count(entries),
         {:ok, normalized} <- normalize_archive_entries(entries),
         :ok <- validate_archive_file_count(normalized),
         :ok <- validate_archive_size(normalized, max_bytes) do
      {:ok, normalized}
    end
  end

  defp validate_archive_entries(_entries, _max_bytes), do: {:error, :invalid_archive}

  defp validate_archive_entry_count(entries) do
    if length(entries) <= @max_archive_entries,
      do: :ok,
      else: {:error, :archive_entry_limit_exceeded}
  end

  defp validate_archive_file_count(entries) do
    if Enum.count(entries, &(&1.type == :regular)) <= @max_archive_files,
      do: :ok,
      else: {:error, :archive_file_limit_exceeded}
  end

  defp validate_archive_size(entries, max_bytes) do
    size = entries |> Enum.filter(&(&1.type == :regular)) |> Enum.sum_by(& &1.size)
    if size <= max_bytes, do: :ok, else: {:error, :archive_expanded_too_large}
  end

  defp normalize_archive_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, normalized} ->
      with {:ok, name, type, size} <- normalize_archive_entry(entry),
           {:ok, path} <- normalize_archive_path(name),
           :ok <- validate_archive_entry_type(type),
           true <- is_integer(size) and size >= 0 do
        {:cont, {:ok, [%{name: name, path: path, type: type, size: size} | normalized]}}
      else
        false -> {:halt, {:error, :invalid_archive}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_archive_entry({name, type, size, _mtime, _mode, _uid, _gid}) do
    {:ok, IO.chardata_to_string(name), type, size}
  rescue
    _error -> {:error, :invalid_archive}
  end

  defp normalize_archive_entry({name, size, type}) do
    {:ok, IO.chardata_to_string(name), type, size}
  rescue
    _error -> {:error, :invalid_archive}
  end

  defp normalize_archive_entry(_entry), do: {:error, :invalid_archive}

  defp normalize_archive_path(name) do
    segments = String.split(name, "/", trim: false)

    cond do
      name == "" ->
        {:error, :unsafe_archive_path}

      Path.type(name) != :relative ->
        {:error, :unsafe_archive_path}

      String.contains?(name, "\\") ->
        {:error, :unsafe_archive_path}

      Enum.any?(segments, &(&1 == "..")) ->
        {:error, :unsafe_archive_path}

      Enum.any?(segments, &Regex.match?(~r/^[A-Za-z]:/, &1)) ->
        {:error, :unsafe_archive_path}

      Enum.any?(segments, &Regex.match?(~r/%2e/i, &1)) ->
        {:error, :unsafe_archive_path}

      true ->
        path = segments |> Enum.reject(&(&1 in ["", "."])) |> Enum.join("/")
        if path == "", do: {:error, :unsafe_archive_path}, else: {:ok, path}
    end
  end

  defp validate_archive_entry_type(type) when type in [:regular, :directory], do: :ok
  defp validate_archive_entry_type(_type), do: {:error, :unsafe_archive_entry}

  defp skill_md_entry?(%{type: :regular, path: path}), do: Path.basename(path) == "SKILL.md"
  defp skill_md_entry?(_entry), do: false

  defp extract_archive_entry(tar, skill_entry) do
    files = [String.to_charlist(skill_entry.name)]

    case :erl_tar.extract({:binary, tar}, [:memory, {:files, files}]) do
      {:ok, extracted} -> extracted_skill_content(extracted, skill_entry.path)
      {:error, _reason} -> {:error, :invalid_archive}
    end
  catch
    _kind, _reason -> {:error, :invalid_archive}
  end

  defp extracted_skill_content(extracted, expected_path) do
    Enum.reduce_while(extracted, {:error, :skill_md_not_found}, fn
      {name, content}, _acc ->
        case normalize_archive_path(IO.chardata_to_string(name)) do
          {:ok, ^expected_path} -> {:halt, {:ok, IO.iodata_to_binary(content)}}
          _other -> {:cont, {:error, :skill_md_not_found}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_archive}}
    end)
  rescue
    _error -> {:error, :invalid_archive}
  end

  defp mcp_capabilities(%{"result" => %{"protocolVersion" => @mcp_protocol_version} = result}) do
    case Map.get(result, "capabilities", %{}) do
      capabilities when is_map(capabilities) ->
        {:ok, capabilities, @mcp_protocol_version}

      _invalid ->
        {:error, :invalid_initialize_response}
    end
  end

  defp mcp_capabilities(%{"result" => %{"protocolVersion" => version}})
       when is_binary(version),
       do: {:error, {:unsupported_mcp_protocol_version, version}}

  defp mcp_capabilities(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp mcp_capabilities(_body), do: {:error, :invalid_initialize_response}

  defp tools_result(%{"result" => %{"tools" => tools} = result}) when is_list(tools) do
    with {:ok, cursor} <- next_cursor(result), do: {:ok, tools, cursor}
  end

  defp tools_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp tools_result(_body), do: {:error, :invalid_tools_response}

  defp prompts_result(%{"result" => %{"prompts" => prompts} = result}) when is_list(prompts) do
    normalize_mcp_page(
      prompts,
      result,
      "name",
      "prompt:",
      "mcp_prompt",
      :invalid_prompts_response
    )
  end

  defp prompts_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp prompts_result(_body), do: {:error, :invalid_prompts_response}

  defp resources_result(%{"result" => %{"resources" => resources} = result})
       when is_list(resources) do
    normalize_mcp_page(
      resources,
      result,
      "uri",
      "resource:",
      "mcp_resource",
      :invalid_resources_response
    )
  end

  defp resources_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp resources_result(_body), do: {:error, :invalid_resources_response}

  defp resource_templates_result(%{"result" => %{"resourceTemplates" => templates} = result})
       when is_list(templates) do
    normalize_mcp_page(
      templates,
      result,
      "uriTemplate",
      "resource_template:",
      "mcp_resource_template",
      :invalid_resource_templates_response
    )
  end

  defp resource_templates_result(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp resource_templates_result(_body), do: {:error, :invalid_resource_templates_response}

  defp normalize_mcp_page(
         entries,
         result,
         identity_key,
         prefix,
         kind,
         invalid_response
       ) do
    with {:ok, normalized} <-
           normalize_mcp_entries(entries, identity_key, prefix, kind, invalid_response),
         {:ok, cursor} <- next_cursor(result) do
      {:ok, normalized, cursor}
    end
  end

  defp normalize_mcp_entries(entries, identity_key, prefix, kind, invalid_response) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, normalized} ->
      case entry do
        %{^identity_key => identity} when is_binary(identity) and identity != "" ->
          capability =
            entry
            |> Map.put("id", prefix <> identity)
            |> Map.put("kind", kind)
            |> Map.put_new("name", identity)

          {:cont, {:ok, [capability | normalized]}}

        _invalid ->
          {:halt, {:error, invalid_response}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp next_cursor(result) do
    case Map.get(result, "nextCursor") do
      nil ->
        {:ok, nil}

      cursor
      when is_binary(cursor) and cursor != "" and byte_size(cursor) <= @max_mcp_cursor_bytes ->
        {:ok, cursor}

      _invalid ->
        {:error, :invalid_mcp_cursor}
    end
  end

  defp remember_cursor(nil, seen_cursors), do: {:ok, seen_cursors}

  defp remember_cursor(cursor, seen_cursors) do
    if MapSet.member?(seen_cursors, cursor),
      do: {:error, :mcp_cursor_cycle},
      else: {:ok, MapSet.put(seen_cursors, cursor)}
  end

  defp session_header(response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [session_id | _] when session_id != "" -> [{"mcp-session-id", session_id}]
      _missing -> []
    end
  end

  defp mcp_accept_headers(headers), do: headers ++ [{"accept", @mcp_accept}]

  defp mcp_session_headers(auth_headers, session_headers, protocol_version) do
    auth_headers ++
      session_headers ++
      [{"mcp-protocol-version", protocol_version}, {"accept", @mcp_accept}]
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

  defp mcp_page_limit(opts) do
    opts
    |> option(:max_mcp_pages, @default_max_mcp_pages)
    |> min(@max_mcp_pages)
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

  defp redact_result({:ok, tools, other_capabilities}, %Connection{} = connection) do
    {:ok, tools, redact_result(other_capabilities, connection)}
  end

  defp redact_result({:incomplete, entries, reason}, %Connection{credential: credential})
       when is_binary(credential) and credential != "" do
    {:incomplete, redact_term(entries, credential), redact_term(reason, credential)}
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
