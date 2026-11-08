defmodule Synapsis.Workflow.Template do
  @moduledoc """
  Trusted consumption of Machine template-render and checked file requests.

  The caller owns and retains the existing schema/template compute PortSession
  across drives and resumes, then closes it separately. This module forwards
  only a completed, correlated receipt's exact tagged string to Machine. File
  bytes are captured through Local and decoded by the same compute helper.
  No native tool or workflow driver is installed here.
  """

  alias Synapsis.Filesystem.Local
  alias Synapsis.Workflow.Machine
  alias Synapsis.Workflow.Schema.PortSession

  @doc "Fulfills the pending render request, preserving state on every failure."
  def advance_pending(session, state, timeout_ms) do
    case ack_pending(session, state, timeout_ms) do
      {:ok, %{ack: ack}} -> Machine.advance(state, ack)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Returns the correlated render ACK and receipt without advancing Machine."
  def ack_pending(
        session,
        %{
          "phase" => "request",
          "heap" => heap,
          "pending_request" => %{"id" => id, "kind" => "render_template"} = request
        },
        timeout_ms
      ) do
    case PortSession.fulfill(session, request, heap, timeout_ms) do
      {:ok, %{"id" => ^id, "result" => "ok", "outcome" => "rendered", "value" => value} = receipt} ->
        {:ok,
         %{
           ack: %{
             "id" => id,
             "kind" => "render_template",
             "result" => "ok",
             "value" => value
           },
           receipt: receipt
         }}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_template_receipt}
    end
  end

  def ack_pending(_session, %{"phase" => "request", "heap" => _}, _timeout_ms),
    do: {:error, :invalid_template_request}

  def ack_pending(_session, _state, _timeout_ms), do: {:error, :no_pending_template_request}

  @doc "Captures the pending file under saved scope and refreshes the live deadline before decode."
  def advance_file(session, state, scope, live_deadline) do
    case ack_file(session, state, scope, live_deadline) do
      {:ok, %{ack: ack}} -> Machine.advance(state, ack)
      {:error, reason} -> {:error, reason, state}
    end
  end

  @doc "Captures and decodes the pending file without consuming its Machine request."
  def ack_file(
        session,
        %{
          "phase" => "request",
          "heap" => heap,
          "pending_request" => %{"id" => id, "kind" => "read_template_file", "file" => file}
        },
        %{"project_root" => root, "cwd" => cwd} = scope,
        live_deadline
      )
      when map_size(scope) == 2 and is_binary(root) and is_binary(cwd) and
             is_function(live_deadline, 0) and is_binary(file) do
    with {:ok, deadline} <- file_deadline(live_deadline),
         cap = min(deadline, now() + 120_000),
         path =
           if(Path.type(file) == :absolute or cwd == ".", do: file, else: cwd <> "/" <> file),
         {:ok, bytes, _relative} <- Local.read_binary(root, path, deadline: cap),
         request = %{
           "id" => id,
           "kind" => "decode_template_file",
           "bytes_base64" => Base.encode64(bytes)
         },
         {:ok, deadline} <- file_deadline(live_deadline),
         timeout = min(cap, deadline) - now(),
         true <- timeout > 0,
         {:ok, receipt} <-
           PortSession.fulfill(
             session,
             request,
             heap,
             timeout
           ) do
      case receipt do
        %{"id" => ^id, "result" => "ok", "outcome" => "decoded", "value" => value} ->
          {:ok,
           %{
             ack: %{
               "id" => id,
               "kind" => "read_template_file",
               "result" => "ok",
               "value" => value
             },
             receipt: receipt
           }}

        _ ->
          {:error, :invalid_template_receipt}
      end
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :timeout}
    end
  end

  def ack_file(
        _session,
        %{"phase" => "request", "heap" => _},
        %{"project_root" => root, "cwd" => cwd} = scope,
        live_deadline
      )
      when map_size(scope) == 2 and is_binary(root) and is_binary(cwd) and
             is_function(live_deadline, 0),
      do: {:error, :invalid_template_request}

  def ack_file(_session, _state, _scope, _live_deadline),
    do: {:error, :invalid_template_file_scope}

  defp file_deadline(callback) do
    case callback.() do
      {:ok, deadline} when is_integer(deadline) ->
        if deadline > now(), do: {:ok, deadline}, else: {:error, :timeout}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_deadline}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
