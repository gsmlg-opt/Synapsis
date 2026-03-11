defmodule Synapsis.Tool.Teammate do
  @moduledoc "Manage teammate agents in a multi-agent swarm."
  use Synapsis.Tool

  @impl true
  def name, do: "teammate"

  @impl true
  def description, do: "Create, list, or manage teammate agents for multi-agent collaboration."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["create", "list", "get", "update"],
          "description" => "Action to perform"
        },
        "name" => %{
          "type" => "string",
          "description" => "Teammate name (for create/get/update)"
        },
        "prompt" => %{
          "type" => "string",
          "description" => "System prompt for the teammate (for create/update)"
        },
        "tools" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "Tools available to teammate"
        },
        "model" => %{"type" => "string", "description" => "Model to use for teammate"}
      },
      "required" => ["action"]
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :swarm

  @impl true
  def execute(input, context) do
    session_id = context[:session_id]

    if is_nil(session_id) do
      {:error, "No session context for swarm management"}
    else
      case input["action"] do
        "create" -> create_teammate(input, session_id)
        "list" -> list_teammates(session_id)
        "get" -> get_teammate(input["name"], session_id)
        "update" -> update_teammate(input, session_id)
        other -> {:error, "Unknown action: #{other}"}
      end
    end
  end

  defp create_teammate(input, session_id) do
    name = input["name"] || "teammate_#{Ecto.UUID.generate()}"
    teammate_id = Ecto.UUID.generate()

    teammate = %{
      id: teammate_id,
      name: name,
      prompt: input["prompt"] || "",
      tools: input["tools"] || ~w(file_read list_dir grep glob),
      model: input["model"],
      status: "active"
    }

    store_teammate(session_id, name, teammate)
    {:ok, Jason.encode!(teammate)}
  end

  defp list_teammates(session_id) do
    teammates = load_teammates(session_id)
    {:ok, Jason.encode!(Map.values(teammates))}
  end

  defp get_teammate(nil, _), do: {:error, "Teammate name is required for 'get' action"}

  defp get_teammate(name, session_id) do
    teammates = load_teammates(session_id)

    case Map.get(teammates, name) do
      nil -> {:error, "Teammate '#{name}' not found"}
      teammate -> {:ok, Jason.encode!(teammate)}
    end
  end

  defp update_teammate(input, session_id) do
    name = input["name"]

    if is_nil(name) do
      {:error, "Teammate name is required for 'update' action"}
    else
      teammates = load_teammates(session_id)

      case Map.get(teammates, name) do
        nil ->
          {:error, "Teammate '#{name}' not found"}

        teammate ->
          updated =
            teammate
            |> maybe_update(:prompt, input["prompt"])
            |> maybe_update(:tools, input["tools"])
            |> maybe_update(:model, input["model"])

          store_teammate(session_id, name, updated)
          {:ok, Jason.encode!(updated)}
      end
    end
  end

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  # --- ETS-backed persistence ---
  # Uses an ETS table owned by the Registry GenServer for swarm state,
  # so state persists across tool invocations within a session.

  @swarm_table :synapsis_swarm_teammates

  @doc false
  def ensure_table do
    if :ets.whereis(@swarm_table) == :undefined do
      :ets.new(@swarm_table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  defp load_teammates(session_id) do
    ensure_table()

    case :ets.lookup(@swarm_table, session_id) do
      [{^session_id, teammates}] -> teammates
      [] -> %{}
    end
  end

  defp store_teammate(session_id, name, teammate) do
    ensure_table()
    teammates = load_teammates(session_id)
    :ets.insert(@swarm_table, {session_id, Map.put(teammates, name, teammate)})
    :ok
  end

  @doc "Delete all teammates for a session."
  def delete_all(session_id) do
    ensure_table()
    count = map_size(load_teammates(session_id))
    :ets.delete(@swarm_table, session_id)
    count
  end
end
