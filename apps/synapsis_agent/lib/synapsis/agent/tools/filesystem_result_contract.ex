defmodule Synapsis.Agent.Tools.FilesystemResultContract do
  @moduledoc """
  Trusted native result allowance for canonical default-resize reads.

  The source permits 4.5 MiB of base64 image data. The complete native result
  retains that image once, plus a finite 1 MiB reserve for text and metadata.
  Base64 is ASCII; JSON reserves six bytes per other input byte. The prepared
  target owns the only source prefix: empty or the pinned resolved-basename note.

  Runtime selects and persists this contract before dispatch. Provider budgets,
  aggregate history and display-only Parts remain independent boundaries.
  Explicit resize-disabled reads retain the ordinary native default.
  """

  alias Backplane.AgentRuntime.Error
  alias Synapsis.Agent.Tools.Filesystem

  @image_bytes 4_718_592
  @envelope_bytes 1_024 * 1_024

  def select(
        %{backend: Filesystem, tool_name: "synapsis::read", tool_revision: 1} = descriptor,
        identity
      ),
      do: selected(descriptor, identity)

  def select(_, _), do: :default

  defp selected(%{backend_context: context} = descriptor, identity)
       when is_map(context) and is_map(identity) do
    with {:ok, issued} <- Filesystem.descriptors(context),
         true <- Enum.any?(issued, &same_binding?(&1, descriptor)),
         true <- identity[:tool_name] === descriptor.tool_name,
         true <- identity[:tool_revision] === descriptor.tool_revision,
         true <-
           identity[:run_id] === context.run_id and identity[:incarnation] === context.incarnation,
         true <-
           is_integer(identity[:catalog_revision]) and
             identity.catalog_revision >= context.catalog_revision do
      if Keyword.get(context.execution_options, :auto_resize_images, true) do
        {:ok,
         %{
           output_limit: @image_bytes + @envelope_bytes,
           json_limit: @image_bytes + 6 * @envelope_bytes
         }}
      else
        :default
      end
    else
      _ -> {:error, Error.new(:validation, "Invalid Filesystem result contract binding")}
    end
  end

  defp selected(_, _),
    do: {:error, Error.new(:validation, "Invalid Filesystem result contract identity")}

  defp same_binding?(issued, descriptor),
    do:
      Map.take(issued, [:backend, :backend_context, :tool_name, :tool_revision, :schema, :safety]) ===
        Map.take(descriptor, [
          :backend,
          :backend_context,
          :tool_name,
          :tool_revision,
          :schema,
          :safety
        ])
end
