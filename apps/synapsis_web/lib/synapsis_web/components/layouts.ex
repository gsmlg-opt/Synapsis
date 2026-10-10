defmodule SynapsisWeb.Layouts do
  @moduledoc """
  Layout components for the Synapsis web interface.
  """
  use SynapsisWeb, :html

  embed_templates "layouts/*"

  attr :info, :map, default: nil

  def version_badge(assigns) do
    info = assigns.info || SynapsisWeb.BuildInfo.info()
    version = "v#{info.version}" <> if(info.environment == :dev, do: "-dev", else: "")

    details =
      Enum.join(
        [
          gettext("Version: %{version}", version: version),
          gettext("Environment: %{environment}", environment: info.environment),
          gettext("Git ref: %{ref}", ref: info.git_ref || gettext("Unknown")),
          gettext("Release time: %{time}",
            time:
              info.release_time ||
                if(info.environment == :dev,
                  do: gettext("Not released"),
                  else: gettext("Not provided")
                )
          ),
          gettext("Build time: %{time}", time: info.build_time)
        ],
        "\n"
      )

    assigns = assign(assigns, version: version, details: details)

    ~H"""
    <.dm_tooltip
      :let={trigger_attrs}
      id="app-version"
      content={@details}
      position="bottom"
      color="secondary"
      class="max-w-sm whitespace-pre-line break-all text-left"
    >
      <button
        id="app-version-trigger"
        type="button"
        class="shrink-0 rounded-full focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
        aria-label={gettext("Version details: %{version}", version: @version)}
        {trigger_attrs}
      >
        <.dm_badge variant="secondary" size="lg" pill class="whitespace-nowrap">
          {@version}
        </.dm_badge>
      </button>
    </.dm_tooltip>
    """
  end
end
