defmodule Synapsis.Web.CitationRedirect do
  @moduledoc "Ordered citation HEAD resolution under the Agent's explicit host policy and search deadline."

  alias Synapsis.Web.Transport

  @redirects [301, 302, 303, 307, 308]
  @chain_timeout 5_000
  @batch_size 10

  def resolve(citations, opts) when is_list(citations) do
    deadline = Keyword.fetch!(opts, :deadline_ms)
    hosts = Keyword.get(opts, :allowed_hosts, [])
    transport = Keyword.get(opts, :transport, &Transport.head/2)

    cond do
      not is_integer(deadline) or deadline <= now() ->
        {:error, :timeout}

      hosts == [] ->
        {:ok, citations}

      true ->
        citations
        |> Enum.chunk_every(@batch_size)
        |> Enum.reduce_while({:ok, []}, fn batch, {:ok, resolved} ->
          case resolve_batch(batch, hosts, deadline, transport) do
            {:ok, rows} -> {:cont, {:ok, resolved ++ rows}}
            error -> {:halt, error}
          end
        end)
    end
  end

  defp resolve_batch(batch, hosts, outer_deadline, transport) do
    if outer_deadline > now() do
      # A barrier joins this entire group before the next group can start.
      # Children and their HTTP tasks remain linked to the native effect owner.
      deadline = min(outer_deadline, now() + @chain_timeout)

      tasks =
        Enum.map(batch, fn citation ->
          Task.async(fn -> resolve_one(citation, hosts, deadline, transport) end)
        end)

      try do
        results = Task.yield_many(tasks, max(0, deadline - now()))

        rows =
          Enum.zip(batch, results)
          |> Enum.map(fn
            {_original, {_task, {:ok, citation}}} -> citation
            {original, {_task, _}} -> original
          end)

        if outer_deadline > now(), do: {:ok, rows}, else: {:error, :timeout}
      after
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
      end
    else
      {:error, :timeout}
    end
  end

  defp resolve_one(%{"url" => original} = citation, hosts, deadline, transport)
       when is_binary(original) do
    with {:ok, uri} <- authorized_uri(original, hosts),
         {:ok, final} <- follow(uri, hosts, deadline, transport, 0) do
      Map.put(citation, "url", final)
    else
      _ -> citation
    end
  rescue
    _ -> citation
  catch
    :exit, _ -> citation
  end

  defp resolve_one(citation, _hosts, _deadline, _transport), do: citation

  defp follow(uri, hosts, deadline, transport, followed) do
    remaining = deadline - now()

    if remaining > 0 do
      case transport.(uri, remaining) do
        {:ok, %{status: status, headers: headers}} when status in @redirects ->
          with true <- followed < 3,
               location when is_binary(location) <- location(headers),
               {:ok, next} <- authorized_uri(URI.merge(uri, location) |> URI.to_string(), hosts) do
            follow(next, hosts, deadline, transport, followed + 1)
          else
            _ -> {:error, :redirect}
          end

        {:ok, %{status: status}} when is_integer(status) ->
          # The source helper uses the final URL independently of HTTP success.
          {:ok, URI.to_string(uri)}

        _ ->
          {:error, :transport}
      end
    else
      {:error, :timeout}
    end
  end

  defp authorized_uri(value, hosts) do
    uri = URI.parse(value)

    if String.valid?(value) and not String.contains?(value, <<0>>) and
         uri.scheme in ["http", "https"] and is_binary(uri.host) and
         String.downcase(uri.host) in hosts and is_nil(uri.userinfo) and is_nil(uri.fragment) do
      {:ok, uri}
    else
      {:error, :host_policy}
    end
  end

  defp location(headers) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "location", do: value

      _ ->
        nil
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
