defmodule Synapsis.Tool.Skill do
  @moduledoc "Load one assigned Skill definition on demand from its frozen catalog entry."
  use Synapsis.Tool

  alias Backplane.SkillProtocol.{Parser, Source.Local, Validator}
  alias Synapsis.SkillCatalog.Entry

  @impl true
  def name, do: "skill"

  @impl true
  def description, do: "Load the complete SKILL.md for an assigned skill locator."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "locator" => %{
          "type" => "string",
          "description" => "Exact locator from the Skill catalog"
        },
        "name" => %{
          "type" => "string",
          "description" => "Temporary compatibility lookup by unique name"
        }
      },
      "anyOf" => [%{"required" => ["locator"]}, %{"required" => ["name"]}],
      "additionalProperties" => false
    }
  end

  @impl true
  def permission_level, do: :none

  @impl true
  def category, do: :orchestration

  @impl true
  def execute(input, context) do
    with {:ok, entry} <- select(input, catalog(context)),
         {:ok, content} <- load(entry, context),
         {:ok, content} <- validate_content(entry, content) do
      {:ok, envelope(entry, content)}
    end
  end

  defp catalog(context) do
    direct = context[:skill_catalog]
    query_context = context[:query_context]

    cond do
      is_list(direct) -> direct
      is_map(query_context) -> query_context.agent_config[:skill_catalog] || []
      true -> []
    end
  end

  defp select(%{"locator" => locator}, catalog) when is_binary(locator) and locator != "" do
    case Enum.find(catalog, &(&1.enabled and &1.locator == locator)) do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, "Skill locator is not assigned to this session"}
    end
  end

  defp select(%{"name" => name}, catalog) when is_binary(name) and name != "" do
    case Enum.filter(catalog, &(&1.enabled and &1.name == name)) do
      [%Entry{} = entry] -> {:ok, entry}
      [] -> {:error, "Skill '#{name}' is not assigned to this session"}
      _many -> {:error, "Skill name '#{name}' is ambiguous; use an exact locator"}
    end
  end

  defp select(_input, _catalog), do: {:error, "An assigned Skill locator or name is required"}

  defp load(%Entry{loader: %{type: :inline}, body: body}, _context) when is_binary(body),
    do: {:ok, body}

  defp load(%Entry{loader: %{type: :local, root: root}} = entry, _context)
       when is_binary(root) do
    with {:ok, descriptors} <-
           Local.discover([%{source_id: entry.source_id, path: root, precedence: 0}]),
         descriptor when not is_nil(descriptor) <-
           Enum.find(descriptors, fn descriptor ->
             descriptor.ref.source_id == entry.source_id and
               descriptor.ref.skill_id == entry.skill_id
           end),
         {:ok, content} <- File.read(descriptor.path) do
      {:ok, content}
    else
      nil -> {:error, "Assigned local Skill is no longer available"}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp load(%Entry{loader: %{type: :backplane}} = entry, context) do
    case context[:skill_loader] do
      loader when is_function(loader, 2) -> loader.(entry, context)
      _ -> {:error, "Backplane Skill source is unavailable"}
    end
  end

  defp load(_entry, _context), do: {:error, "Skill source is unavailable"}

  defp validate_content(%Entry{loader: %{type: :inline, canonical?: false}}, content),
    do: {:ok, content}

  defp validate_content(_entry, content) do
    with {:ok, document} <- Parser.parse(content),
         {:ok, document} <- Validator.validate(document, profile: :legacy) do
      {:ok, document.raw}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp envelope(entry, content) do
    """
    <skill>
    <name>#{xml_escape(entry.name)}</name>
    <locator>#{xml_escape(entry.locator)}</locator>
    <contents>
    #{content}
    </contents>
    </skill>
    """
    |> String.trim()
  end

  defp xml_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp format_error(%{message: message}) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason)
end
