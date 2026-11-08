defmodule Synapsis.Automation.Webhook do
  @moduledoc """
  Primary automation POST transport for the Agent-owned HTTP task.

  The caller owns task lifetime, the absolute deadline and Run identity. Progress
  callbacks synchronously acknowledge each fact before the next external step.
  A 2xx is acknowledged before response cleanup; response bodies are discarded.
  """

  @attempt_timeout 10_000

  @doc "Post already encoded JSON under the existing absolute monotonic deadline."
  def deliver(url, encoded_json, deadline, progress)
      when is_binary(url) and is_binary(encoded_json) and is_integer(deadline) and
             is_function(progress, 1) do
    if remaining(deadline) > 0 do
      attempted = %{"status" => "unknown", "attempted" => true, "attempt_count" => 1}

      case acknowledge(progress, attempted) do
        :ok ->
          if remaining(deadline) > 0 do
            request(url, encoded_json, deadline, progress, attempted)
          else
            {:ok, not_attempted("webhook_deadline_exceeded")}
          end

        :error ->
          {:ok, not_attempted("webhook_progress_unacknowledged")}
      end
    else
      {:ok, not_attempted("webhook_deadline_exceeded")}
    end
  end

  defp request(url, encoded_json, deadline, progress, attempted) do
    timeout = min(@attempt_timeout, remaining(deadline))

    result =
      Req.Request.new()
      |> Req.Steps.attach()
      |> Req.merge(
        method: :post,
        url: url,
        headers: [{"content-type", "application/json"}],
        body: encoded_json,
        into: :self,
        raw: true,
        compressed: false,
        retry: false,
        redirect: false,
        receive_timeout: timeout,
        request_timeout: timeout,
        finch: [pool_timeout: timeout, conn_opts: [transport_opts: [timeout: timeout]]]
      )
      |> perform()

    case result do
      {:ok, response} -> settle(response, progress, attempted)
      {:error, _reason} -> {:ok, Map.put(attempted, "error", "webhook_request_unconfirmed")}
    end
  end

  defp perform(request) do
    Req.request(request)
  rescue
    _ -> {:error, :request_unconfirmed}
  catch
    :exit, _ -> {:error, :request_unconfirmed}
  end

  defp settle(response, progress, attempted) do
    accepted? = response.status in 200..299

    outcome =
      attempted
      |> Map.put("status", if(accepted?, do: "delivered", else: "not-delivered"))
      |> Map.put("delivered", accepted?)
      |> Map.put("http_status", response.status)

    outcome =
      if accepted?,
        do: outcome,
        else: Map.put(outcome, "error", "Webhook request failed with HTTP #{response.status}")

    try do
      case acknowledge(progress, outcome) do
        :ok -> {:ok, outcome}
        :error -> {:ok, Map.put(attempted, "error", "webhook_progress_unacknowledged")}
      end
    after
      discard_response(response)
    end
  end

  defp acknowledge(progress, observation) do
    if progress.(observation) == :ok, do: :ok, else: :error
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp discard_response(%Req.Response{body: %Req.Response.Async{}} = response) do
    Req.cancel_async_response(response)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp discard_response(_response), do: :ok

  # The pinned direct-delivery policy requires typed proven-not-sent evidence
  # before retrying. A plain HTTP rejection has no such marker, and Req's generic
  # transport errors do not prove a POST was unsent. Neither is retried here.
  defp not_attempted(error) do
    %{
      "status" => "not-delivered",
      "attempted" => false,
      "delivered" => false,
      "attempt_count" => 0,
      "error" => error
    }
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
