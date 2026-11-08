defmodule SynapsisWeb.AgentLive.BrowserSettings do
  @moduledoc false
  use Phoenix.Component
  use PhoenixDuskmoon.Component

  @fields ~w(default_profile node_executable helper_path)
  @profile_fields ~w(executable data_dir timeout_ms max_image_bytes)

  def form_values(config) do
    browser = map(config["browser"])
    profiles = browser |> Map.get("profiles") |> map() |> Enum.sort() |> Enum.take(8)

    Map.new(@fields, &{&1, text(browser[&1])})
    |> Map.put("remove", false)
    |> Map.put(
      "profiles",
      Map.new(0..7, fn index ->
        {name, profile} = Enum.at(profiles, index, {"", %{}})
        values = Map.new(@profile_fields, &{&1, text(map(profile)[&1])})
        {to_string(index), values |> Map.put("name", text(name)) |> Map.put("remove", false)}
      end)
    )
  end

  # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#210
  # Upstream submit rereads disabled numeric inputs; connected save acceptance
  # for unsupported values remains blocked until the released hook preserves them.
  # Compare with the originally loaded representation, never a typing preview.
  # Unchanged submissions preserve absent/null/unsupported data and fresh store edits.
  def apply_config(config, original, submitted) do
    cond do
      is_nil(submitted) or canonical(submitted) == canonical(form_values(original)) ->
        {:ok, config}

      Map.fetch(config, "browser") != Map.fetch(original, "browser") ->
        {:error,
         "Browser configuration changed in another editor. Reload the Agent before saving Browser changes."}

      checked?(submitted["remove"]) ->
        {:ok, Map.delete(config, "browser")}

      not editable?(original) ->
        {:error,
         "Saved Browser configuration is not supported by this editor. Keep it unchanged or explicitly remove it before configuring profiles."}

      true ->
        with {:ok, browser} <- parse(submitted) do
          {:ok, Map.put(config, "browser", browser)}
        end
    end
  end

  defp parse(submitted) do
    slots = submitted |> Map.get("profiles") |> map() |> Enum.sort()

    with {:ok, profiles} <- parse_profiles(slots),
         :ok <-
           validate_field(
             map_size(profiles) in 1..8,
             "Add one to eight named Browser profiles, or select Remove Browser configuration."
           ),
         :ok <-
           validate_field(
             Map.has_key?(profiles, submitted["default_profile"]),
             "Default Browser profile must match one of the profile names."
           ),
         :ok <-
           validate_field(
             absolute?(submitted["node_executable"]),
             "Node executable must be an absolute path."
           ),
         :ok <-
           validate_field(
             absolute?(submitted["helper_path"]),
             "Browser helper must be an absolute path."
           ) do
      {:ok, submitted |> Map.take(@fields) |> Map.put("profiles", profiles)}
    end
  end

  defp parse_profiles(slots) do
    Enum.reduce_while(slots, {:ok, %{}}, fn {_index, slot}, {:ok, profiles} ->
      cond do
        checked?(slot["remove"]) or blank_slot?(slot) ->
          {:cont, {:ok, profiles}}

        true ->
          case parse_profile(slot, profiles) do
            {:ok, profile} -> {:cont, {:ok, Map.put(profiles, slot["name"], profile)}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp parse_profile(slot, profiles) do
    name = slot["name"]

    with :ok <-
           validate_field(
             profile_name?(name),
             "Browser profile names must be 1–128 letters, digits, underscores or hyphens, starting with a letter or digit."
           ),
         :ok <-
           validate_field(
             not Map.has_key?(profiles, name),
             "Browser profile names must be unique: #{name}."
           ),
         :ok <-
           validate_field(
             absolute?(slot["executable"]),
             "Browser executable for #{name} must be an absolute path."
           ),
         :ok <-
           validate_field(
             absolute?(slot["data_dir"]),
             "Browser data directory for #{name} must be an absolute path."
           ),
         {:ok, timeout} <- optional_integer(slot["timeout_ms"], 120_000, "Timeout for #{name}"),
         {:ok, image} <-
           optional_integer(slot["max_image_bytes"], 196_608, "Image budget for #{name}") do
      profile = %{
        "target" => "host",
        "driver" => "managed-host",
        "executable" => slot["executable"],
        "data_dir" => slot["data_dir"]
      }

      {:ok,
       profile |> put_optional("timeout_ms", timeout) |> put_optional("max_image_bytes", image)}
    end
  end

  defp optional_integer(value, _max, _label) when value in [nil, ""], do: {:ok, nil}

  defp optional_integer(value, max, label) do
    case Integer.parse(text(value)) do
      {number, ""} when number >= 1 and number <= max -> {:ok, number}
      _ -> {:error, "#{label} must be a whole number from 1 to #{max}, or blank for the default."}
    end
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
  defp validate_field(true, _message), do: :ok
  defp validate_field(false, message), do: {:error, message}
  defp blank_slot?(slot), do: Enum.all?(["name" | @profile_fields], &(slot[&1] in [nil, ""]))
  defp checked?(value), do: value in [true, "true", "on"]

  defp editable?(config) do
    case config["browser"] do
      nil -> true
      browser when is_map(browser) -> supported?(browser)
      _ -> false
    end
  end

  defp supported?(browser) do
    profiles = browser["profiles"]

    Map.keys(browser) -- ["profiles" | @fields] == [] and
      absolute?(browser["node_executable"]) and absolute?(browser["helper_path"]) and
      is_map(profiles) and map_size(profiles) in 1..8 and
      profile_name?(browser["default_profile"]) and
      Map.has_key?(profiles, browser["default_profile"]) and
      Enum.all?(profiles, fn {name, profile} ->
        profile_name?(name) and is_map(profile) and
          Map.keys(profile) -- ["target", "driver" | @profile_fields] == [] and
          profile["target"] == "host" and profile["driver"] == "managed-host" and
          absolute?(profile["executable"]) and absolute?(profile["data_dir"]) and
          optional_range?(profile, "timeout_ms", 120_000) and
          optional_range?(profile, "max_image_bytes", 196_608)
      end)
  end

  defp optional_range?(profile, key, max),
    do: not Map.has_key?(profile, key) or (is_integer(profile[key]) and profile[key] in 1..max)

  defp profile_name?(name),
    do:
      is_binary(name) and byte_size(name) in 1..128 and String.valid?(name) and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, name)

  defp absolute?(path),
    do:
      is_binary(path) and String.valid?(path) and not String.contains?(path, "\0") and
        Path.type(path) == :absolute

  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_integer(value), do: to_string(value)
  defp text(_), do: ""

  defp canonical(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {key, canonical(value)} end)

  defp canonical(value) when is_boolean(value), do: to_string(value)
  defp canonical(value), do: value

  attr :config, :map, required: true
  attr :draft, :any, default: nil

  def editor(assigns) do
    assigns =
      assigns
      |> assign(:values, assigns.draft || form_values(assigns.config))
      |> assign(:editable, editable?(assigns.config))

    ~H"""
    <section id="agent-browser-settings" class="mt-5 space-y-3 border-t border-outline-variant pt-5">
      <div>
        <h4 class="text-sm font-semibold">Browser configuration</h4>
        <p class="text-xs text-on-surface-variant">
          Configure one to eight host profiles, then explicitly select the Browser tool in a Toolset.
          Saving these settings does not select the tool. Target: host · Driver: managed-host.
          Leave unused profile slots blank; names use letters, digits, underscores or hyphens.
        </p>
      </div>
      <p :if={!@editable} class="text-sm text-warning">
        Saved Browser configuration uses fields or values this editor does not support.
        It is preserved unchanged. Explicitly remove it to configure supported profiles.
      </p>
      <.dm_checkbox
        name="browser_settings[remove]"
        value="true"
        checked={checked?(@values["remove"])}
        label="Remove Browser configuration on save"
      />
      <fieldset disabled={!@editable} class="space-y-3">
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
          <.dm_input
            disabled={!@editable}
            id="browser-default-profile"
            name="browser_settings[default_profile]"
            label="Default profile"
            value={@values["default_profile"]}
          />
          <.dm_input
            disabled={!@editable}
            id="browser-node-executable"
            name="browser_settings[node_executable]"
            label="Node executable (absolute path)"
            value={@values["node_executable"]}
          />
          <.dm_input
            disabled={!@editable}
            id="browser-helper-path"
            name="browser_settings[helper_path]"
            label="Browser helper (absolute path)"
            value={@values["helper_path"]}
          />
        </div>
        <details
          :for={index <- 0..7}
          id={"browser-profile-#{index}"}
          open={@values["profiles"][to_string(index)]["name"] != ""}
          class="rounded border border-outline-variant p-3"
        >
          <summary class="cursor-pointer text-sm font-medium">Profile {index + 1}</summary>
          <div class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
            <.dm_input
              disabled={!@editable}
              id={"browser-profile-#{index}-name"}
              name={"browser_settings[profiles][#{index}][name]"}
              label="Profile name"
              value={@values["profiles"][to_string(index)]["name"]}
            />
            <.dm_input
              disabled={!@editable}
              id={"browser-profile-#{index}-executable"}
              name={"browser_settings[profiles][#{index}][executable]"}
              label="Browser executable (absolute path)"
              value={@values["profiles"][to_string(index)]["executable"]}
            />
            <.dm_input
              disabled={!@editable}
              id={"browser-profile-#{index}-data-dir"}
              name={"browser_settings[profiles][#{index}][data_dir]"}
              label="Data directory (absolute path)"
              value={@values["profiles"][to_string(index)]["data_dir"]}
            />
            <.dm_input
              disabled={!@editable}
              type="number"
              id={"browser-profile-#{index}-timeout-ms"}
              name={"browser_settings[profiles][#{index}][timeout_ms]"}
              label="Timeout (ms, optional)"
              helper="Blank uses 15000 ms; range 1–120000."
              value={@values["profiles"][to_string(index)]["timeout_ms"]}
              min="1"
              max="120000"
            />
            <.dm_input
              disabled={!@editable}
              type="number"
              id={"browser-profile-#{index}-max-image-bytes"}
              name={"browser_settings[profiles][#{index}][max_image_bytes]"}
              label="Image budget (bytes, optional)"
              helper="Blank uses 196608 bytes; range 1–196608."
              value={@values["profiles"][to_string(index)]["max_image_bytes"]}
              min="1"
              max="196608"
            />
            <.dm_checkbox
              disabled={!@editable}
              id={"browser-profile-#{index}-remove"}
              name={"browser_settings[profiles][#{index}][remove]"}
              value="true"
              checked={checked?(@values["profiles"][to_string(index)]["remove"])}
              label="Remove this profile on save"
            />
          </div>
        </details>
      </fieldset>
    </section>
    """
  end
end
