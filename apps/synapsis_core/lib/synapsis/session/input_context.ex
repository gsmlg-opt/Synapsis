defmodule Synapsis.Session.InputContext do
  @moduledoc """
  Portable provenance captured by a trusted host prompt ingress.

  The ingress supplies either explicit messaging identities or an operator
  requester and a fixed presentation origin. These constructors choose no
  identity mapping and authenticate no caller or arbitrary map. They generate
  one input UUID, retained through direct and queued prompt preparation.
  Source session is provenance, not sender identity.

  Keep this map separate from posted content, model arguments and configuration.
  Old internal send APIs retain unavailable provenance. Native child tasks and
  internal events must not inherit this as their own user-triggered input.
  """

  @identity_keys ~w(provider account_id conversation_id sender_id)a
  @keys ~w(version trigger provider account_id conversation_id sender_id source_session_id input_id)
  @operator_identity_keys ~w(requester_id origin)a
  @operator_keys ~w(version kind trigger requester_id origin source_session_id input_id)
  @operator_origins ~w(liveview rest channel)

  @spec capture(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def capture(session_id, identity) when is_map(identity) and not is_struct(identity) do
    with :ok <- uuid(session_id),
         true <- Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys),
         true <- Enum.all?(@identity_keys, &text?(identity[&1])) do
      {:ok,
       identity
       |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
       |> Map.merge(%{
         "version" => 1,
         "trigger" => "user",
         "source_session_id" => session_id,
         "input_id" => Ecto.UUID.generate()
       })}
    else
      _ -> {:error, :invalid_input_context}
    end
  end

  def capture(_, _), do: {:error, :invalid_input_context}

  @doc "Capture the operator identity supplied by a trusted presentation ingress."
  @spec capture_operator(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def capture_operator(session_id, identity) when is_map(identity) and not is_struct(identity) do
    with :ok <- uuid(session_id),
         true <- Enum.sort(Map.keys(identity)) == Enum.sort(@operator_identity_keys),
         true <- text?(identity.requester_id),
         true <- identity.origin in @operator_origins do
      {:ok,
       %{
         "version" => 1,
         "kind" => "operator",
         "trigger" => "user",
         "requester_id" => identity.requester_id,
         "origin" => identity.origin,
         "source_session_id" => session_id,
         "input_id" => Ecto.UUID.generate()
       }}
    else
      _ -> {:error, :invalid_input_context}
    end
  end

  def capture_operator(_, _), do: {:error, :invalid_input_context}

  @doc "Check the complete portable shape and its destination; this is not authentication."
  @spec validate(map(), String.t()) :: :ok | {:error, atom()}
  def validate(%{"kind" => "operator"} = context, session_id) when not is_struct(context) do
    with :ok <- uuid(session_id),
         :ok <- uuid(context["input_id"]),
         true <- Enum.sort(Map.keys(context)) == Enum.sort(@operator_keys),
         true <- context["version"] === 1 and context["trigger"] == "user",
         true <- context["source_session_id"] == session_id,
         true <- text?(context["requester_id"]),
         true <- context["origin"] in @operator_origins do
      :ok
    else
      _ -> {:error, :invalid_input_context}
    end
  end

  def validate(context, session_id) when is_map(context) and not is_struct(context) do
    with :ok <- uuid(session_id),
         :ok <- uuid(context["input_id"]),
         true <- Enum.sort(Map.keys(context)) == Enum.sort(@keys),
         true <- context["version"] === 1 and context["trigger"] == "user",
         true <- context["source_session_id"] == session_id,
         true <- Enum.all?(@identity_keys, &text?(context[Atom.to_string(&1)])) do
      :ok
    else
      _ -> {:error, :invalid_input_context}
    end
  end

  def validate(_, _), do: {:error, :invalid_input_context}

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> :ok
      _ -> {:error, :invalid_input_context}
    end
  end

  defp text?(value),
    do:
      is_binary(value) and String.valid?(value) and String.trim(value) != "" and
        not String.contains?(value, "\0")
end
