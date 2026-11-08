defmodule Synapsis.PDF.Source do
  @moduledoc "Bounded binary PDF acquisition with at most three HTTP redirects under one deadline."

  alias Synapsis.Filesystem.Local

  @max_bytes 10 * 1024 * 1024
  @redirect_statuses [301, 302, 303, 307, 308]
  @max_redirects 3

  def load(reference, context, max_bytes, deadline)
      when is_binary(reference) and is_map(context) and is_integer(max_bytes) and
             max_bytes in 1..@max_bytes and is_integer(deadline) do
    with true <-
           String.valid?(reference) and byte_size(reference) in 1..4096 and
             not String.contains?(reference, <<0>>),
         true <- deadline > now(),
         {:ok, bytes, resolved, rewritten} <-
           acquire(String.trim(reference), context, max_bytes, deadline),
         true <- pdf?(bytes) do
      {:ok, %{bytes: bytes, resolved_input: resolved, rewritten_from: rewritten}}
    else
      false -> {:error, :invalid_pdf_source}
      error -> error
    end
  rescue
    _ -> {:error, :pdf_source_unavailable}
  end

  def load(_, _, _, _), do: {:error, :invalid_pdf_source}

  defp acquire(reference, context, limit, deadline) do
    case URI.parse(reference) do
      %URI{scheme: scheme} = uri when scheme in ["http", "https"] ->
        hosts = context[:web_allowed_hosts] || []

        if http_source?(uri, hosts) do
          with {:ok, bytes} <- download(uri, hosts, limit, deadline),
               do: {:ok, bytes, URI.to_string(uri), nil}
        else
          {:error, :unsupported_pdf_source}
        end

      %URI{scheme: "file", host: host, query: nil, fragment: nil, userinfo: nil, path: path}
      when host in [nil, "", "localhost"] and is_binary(path) ->
        local(URI.decode(path), reference, context, limit, deadline)

      %URI{scheme: nil} ->
        local(reference, reference, context, limit, deadline)

      _ ->
        {:error, :unsupported_pdf_source}
    end
  end

  defp local(path, original, context, limit, deadline) do
    with root when is_binary(root) <- context[:project_root],
         {:ok, absolute, _} <- Local.resolve(root, path),
         {:ok, bytes, _} <- Local.read_binary(root, path, max_bytes: limit, deadline: deadline) do
      {:ok, bytes, absolute, if(original == absolute, do: nil, else: original)}
    else
      {:error, _} = error -> error
      _ -> {:error, :unsupported_pdf_source}
    end
  end

  defp http_source?(%URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}, hosts)
       when scheme in ["http", "https"] and is_binary(host),
       do: String.downcase(host) in hosts

  defp http_source?(_, _), do: false

  defp download(uri, hosts, limit, deadline) do
    timeout = deadline - now()

    if timeout > 0 do
      task = Task.async(fn -> follow_redirects(uri, hosts, limit, deadline, 0) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :pdf_source_timeout}
      end
    else
      {:error, :pdf_source_timeout}
    end
  end

  defp follow_redirects(uri, hosts, limit, deadline, redirects) do
    timeout = deadline - now()

    if timeout > 0 do
      case request(uri, limit, timeout) do
        {:redirect, location} when redirects < @max_redirects ->
          with true <-
                 is_binary(location) and byte_size(location) in 1..4096 and
                   String.valid?(location) and not String.contains?(location, <<0>>),
               next = URI.merge(uri, location),
               true <- http_source?(next, hosts) do
            follow_redirects(next, hosts, limit, deadline, redirects + 1)
          else
            _ -> {:error, :unsupported_pdf_source}
          end

        {:redirect, _} ->
          {:error, :pdf_source_unavailable}

        result ->
          result
      end
    else
      {:error, :pdf_source_timeout}
    end
  rescue
    _ -> {:error, :unsupported_pdf_source}
  end

  defp request(uri, limit, timeout) do
    result =
      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        method: :get,
        url: URI.to_string(uri),
        raw: true,
        compressed: false,
        into: fn event, pair -> collect(event, pair, limit) end,
        retry: false,
        redirect: false,
        receive_timeout: timeout,
        request_timeout: timeout,
        finch: [pool_timeout: timeout, conn_opts: [transport_opts: [timeout: timeout]]]
      )
      |> Req.request()

    case result do
      {:ok, %{status: 200} = response} ->
        type =
          response
          |> Req.Response.get_header("content-type")
          |> List.first("")
          |> String.split(";")
          |> hd()
          |> String.trim()
          |> String.downcase()

        case Req.Response.get_private(response, :pdf_body) do
          {_, chunks} when type == "application/pdf" ->
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

          _ ->
            {:error, :invalid_pdf_source}
        end

      {:ok, %{status: status} = response} when status in @redirect_statuses ->
        if Req.Response.get_private(response, :pdf_body) == :over_limit,
          do: {:error, :invalid_pdf_source},
          else: {:redirect, response |> Req.Response.get_header("location") |> List.first()}

      _ ->
        {:error, :pdf_source_unavailable}
    end
  rescue
    _ -> {:error, :pdf_source_unavailable}
  catch
    :exit, _ -> {:error, :pdf_source_unavailable}
  end

  defp collect({:data, data}, {request, response}, limit) do
    case Req.Response.get_private(response, :pdf_body, {0, []}) do
      {size, chunks} when size + byte_size(data) <= limit ->
        {:cont,
         {request,
          Req.Response.put_private(response, :pdf_body, {size + byte_size(data), [data | chunks]})}}

      _ ->
        {:halt, {request, Req.Response.put_private(response, :pdf_body, :over_limit)}}
    end
  end

  defp collect(_, pair, _), do: {:cont, pair}

  defp pdf?(bytes) do
    prefix = binary_part(bytes, 0, min(byte_size(bytes), 1024))
    :binary.match(prefix, "%PDF-") != :nomatch
  end

  defp now, do: System.monotonic_time(:millisecond)
end
