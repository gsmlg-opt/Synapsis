defmodule Synapsis.Diffs.Config do
  @moduledoc "Pure source-compatible Diffs configuration, backed by the TOML singleton."

  alias Synapsis.Config.Store

  @defaults %{
    "fontFamily" => "Fira Code",
    "fontSize" => 15,
    "lineSpacing" => 1.6,
    "layout" => "unified",
    "showLineNumbers" => true,
    "diffIndicators" => "bars",
    "wordWrap" => true,
    "background" => true,
    "theme" => "dark",
    "fileFormat" => "png",
    "fileQuality" => "standard",
    "fileScale" => 2,
    "fileMaxWidth" => 960,
    "mode" => "both",
    "ttlSeconds" => 1800
  }
  @aliases ~w(format imageFormat imageQuality imageScale imageMaxWidth)
  @enums %{
    "layout" => ~w(unified split),
    "diffIndicators" => ~w(bars classic none),
    "theme" => ~w(light dark),
    "fileFormat" => ~w(png pdf),
    "imageFormat" => ~w(png pdf),
    "format" => ~w(png pdf),
    "fileQuality" => ~w(standard hq print),
    "imageQuality" => ~w(standard hq print),
    "mode" => ~w(view file image both)
  }
  @numbers %{
    "fontSize" => {10, 24},
    "lineSpacing" => {1, 3},
    "fileScale" => {1, 4},
    "imageScale" => {1, 4},
    "fileMaxWidth" => {640, 2400},
    "imageMaxWidth" => {640, 2400},
    "ttlSeconds" => {1, 21_600}
  }

  def load do
    case Store.get(:diffs, "default") do
      {:ok, entry} -> resolve(entry)
      {:error, :not_found} -> resolve(%{})
      error -> error
    end
  end

  def resolve(attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    defaults = Map.get(attrs, "defaults", %{})
    security = Map.get(attrs, "security", %{})
    host = Map.get(attrs, "host", %{})

    with true <- only?(attrs, ~w(id defaults security viewerBaseUrl host)),
         true <- Map.get(attrs, "id", "default") == "default",
         true <- valid_defaults?(defaults),
         true <- is_map(security) and only?(security, ~w(allowRemoteViewer)),
         true <- is_boolean(Map.get(security, "allowRemoteViewer", false)),
         {:ok, host} <- resolve_host(host),
         {:ok, url} <- normalize_url(Map.get(attrs, "viewerBaseUrl")) do
      resolved = %{
        "id" => "default",
        "defaults" => resolve_defaults(defaults),
        "security" => %{"allowRemoteViewer" => Map.get(security, "allowRemoteViewer", false)},
        "host" => host
      }

      {:ok, if(url, do: Map.put(resolved, "viewerBaseUrl", url), else: resolved)}
    else
      _ -> {:error, :invalid_diffs_config}
    end
  end

  def resolve(_), do: {:error, :invalid_diffs_config}

  defp valid_defaults?(defaults) when is_map(defaults) do
    only?(defaults, Map.keys(@defaults) ++ @aliases) and
      Enum.all?(defaults, fn {key, value} ->
        cond do
          key == "fontFamily" ->
            is_binary(value) and String.valid?(value)

          Map.has_key?(@enums, key) ->
            value in Map.fetch!(@enums, key)

          Map.has_key?(@numbers, key) ->
            {low, high} = Map.fetch!(@numbers, key)
            is_number(value) and value >= low and value <= high

          true ->
            is_boolean(value)
        end
      end)
  end

  defp valid_defaults?(_), do: false

  defp resolve_defaults(values) do
    quality = values["fileQuality"] || values["imageQuality"] || "standard"

    {scale, width} =
      Map.fetch!(%{"standard" => {2, 960}, "hq" => {2.5, 1200}, "print" => {3, 1400}}, quality)

    font = String.trim(Map.get(values, "fontFamily", "Fira Code"))

    @defaults
    |> Map.merge(Map.drop(values, @aliases))
    |> Map.put("fontFamily", if(font == "", do: "Fira Code", else: font))
    |> Map.put("fontSize", trunc(Map.get(values, "fontSize", 15)))
    |> Map.put("ttlSeconds", trunc(Map.get(values, "ttlSeconds", 1800)))
    |> Map.put(
      "fileFormat",
      values["fileFormat"] || values["imageFormat"] || values["format"] || "png"
    )
    |> Map.put("fileQuality", quality)
    |> Map.put(
      "fileScale",
      floor((values["fileScale"] || values["imageScale"] || scale) * 100 + 0.5) / 100
    )
    |> Map.put(
      "fileMaxWidth",
      floor((values["fileMaxWidth"] || values["imageMaxWidth"] || width) + 0.5)
    )
  end

  defp resolve_host(host) when is_map(host) do
    timeout = Map.get(host, "timeoutMs", 120_000)
    root = Map.get(host, "artifactRoot", Path.join(Path.expand(Store.config_dir()), "diffs"))

    if only?(host, ~w(nodeExecutable chromiumExecutable helperPath artifactRoot timeoutMs)) and
         is_integer(timeout) and timeout in 1..120_000 and absolute?(root) and
         Enum.all?(~w(nodeExecutable chromiumExecutable helperPath), fn key ->
           not Map.has_key?(host, key) or absolute?(host[key])
         end) do
      {:ok, host |> Map.put("timeoutMs", timeout) |> Map.put("artifactRoot", Path.expand(root))}
    else
      {:error, :invalid_host}
    end
  end

  defp resolve_host(_), do: {:error, :invalid_host}

  defp normalize_url(nil), do: {:ok, nil}

  defp normalize_url(raw) when is_binary(raw) do
    raw = String.trim(raw)
    uri = URI.parse(raw)

    cond do
      raw == "" ->
        {:ok, nil}

      String.downcase(uri.scheme || "") not in ~w(http https) ->
        {:error, :invalid_url}

      is_nil(uri.host) or uri.host == "" or not is_nil(uri.query) or not is_nil(uri.fragment) ->
        {:error, :invalid_url}

      true ->
        uri = %{
          uri
          | scheme: String.downcase(uri.scheme),
            host: String.downcase(uri.host),
            path: String.trim_trailing(uri.path || "", "/")
        }

        {:ok, URI.to_string(uri) |> String.trim_trailing("/")}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp normalize_url(_), do: {:error, :invalid_url}

  defp absolute?(value),
    do:
      is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>) and
        Path.type(value) == :absolute

  defp only?(map, keys), do: Enum.all?(Map.keys(map), &(&1 in keys))

  defp stringify(map) when is_map(map),
    do:
      Map.new(map, fn {key, value} ->
        {to_string(key), if(is_map(value), do: stringify(value), else: value)}
      end)
end
