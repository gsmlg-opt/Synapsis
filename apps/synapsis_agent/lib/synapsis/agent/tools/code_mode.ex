defmodule Synapsis.Agent.Tools.CodeMode do
  @moduledoc """
  Builds original native Code Mode descriptors for the selected static catalog.

  The existing native Session owns workers and continuations. Conversation
  supplies the admitted nested dispatcher and its pinned catalog snapshot.
  """

  alias Backplane.AgentRuntime.{Codex, Error, InputSchema}
  alias Backplane.AgentRuntime.Codex.{Backend, CodeMode, Session}

  @names ~w(exec wait)

  def names, do: @names
  def permission_level(name) when name in @names, do: :execute

  def bundles(context, authority, selection) do
    selected = Enum.filter(selection, &(&1 in @names))

    cond do
      selected == [] ->
        {:ok, []}

      not Enum.all?(selected, &(&1 in authority.grants)) ->
        unavailable("selected tools exceed the parent authority ceiling")

      true ->
        with {:ok, deno} <- deno(),
             :ok <- lifecycle(context),
             native_authority = %{
               authority
               | grants: selected,
                 tool_revisions: Map.take(authority.tool_revisions, selected)
             },
             {:ok, bundle} <-
               Codex.profile(
                 :code_mode,
                 Map.put(context, :deno_path, deno),
                 native_authority,
                 tools: selected
               ) do
          {:ok, [bundle]}
        end
    end
  end

  def classify(
        %{
          backend: Backend,
          backend_context: %{family: :code_mode, session_binding: binding}
        } = descriptor,
        identity,
        invocation
      ) do
    with true <-
           descriptor.tool_name in @names and
             invocation[:tool_name] === descriptor.tool_name and
             invocation[:tool_revision] === descriptor.tool_revision,
         :ok <- Synapsis.Agent.Tools.CatalogBinding.descriptor(descriptor, identity, invocation),
         {:ok, _} <- Session.validate(binding, invocation),
         :ok <- arguments(descriptor, invocation[:arguments]) do
      {:ok,
       %{
         action: "code_mode." <> descriptor.tool_name,
         resource: "code_mode:session:" <> identity.session_id
       }}
    else
      false -> {:error, :scope_mismatch}
      error -> error
    end
  end

  def classify(_, _, _), do: {:error, :unsupported_classification}

  defp arguments(%{tool_name: "exec", codex_input_kind: :custom}, raw)
       when is_binary(raw),
       do: :ok

  defp arguments(%{tool_name: "wait", schema: schema}, arguments) do
    case InputSchema.validate(schema, arguments) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp arguments(_, _), do: {:error, :invalid_arguments}

  defp deno do
    case System.find_executable("deno") do
      nil -> unavailable("Deno is missing from PATH; enter the managed devenv shell")
      path -> {:ok, path}
    end
  end

  defp lifecycle(context) do
    case CodeMode.lifecycle_capability(context) do
      :verified -> :ok
      {:unsupported, reason} -> unavailable("process lifecycle verification requires #{reason}")
    end
  end

  defp unavailable(reason),
    do: {:error, Error.new(:unsupported_capability, "Code Mode unavailable: " <> reason)}
end
