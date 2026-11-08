defmodule Synapsis.Agent.Tools.Web.Fetch do
  @moduledoc "Selected native fetch profile with trusted Agent configuration and fresh host classification."

  alias Backplane.AgentRuntime.{Codex, Error, InputSchema}
  alias Backplane.AgentRuntime.Codex.{Backend, Services}
  alias Synapsis.{AgentConfig, AgentConfigs}

  @names ["web::fetch"]
  def names, do: @names

  # Derive the parent ceiling from the same official configured service contract
  # used at admission. Never patch an already-issued revision or schema.
  def revision do
    Services.definitions(%{web_fetch_adapter: Synapsis.Web.Fetch})
    |> Enum.find(&(&1.tool_name == "web::fetch"))
    |> Map.fetch!(:tool_revision)
  end

  def permission_level("web::fetch"), do: :read

  def bundles(context, identity, authority, selection, binding) do
    if "web::fetch" in selection do
      with {:ok, agent, hosts} <- configuration(context.agent[:name]),
           true <- "web::fetch" in authority.grants do
        scope = %{
          identity: identity,
          agent_id: agent.id,
          agent_name: agent.name,
          hosts_fingerprint: fingerprint(hosts)
        }

        native_context = %{
          web_allowed_hosts: hosts,
          web_transport: Synapsis.Web.Transport,
          web_fetch_adapter: Synapsis.Web.Fetch,
          web_fetch_options: [
            node_executable: Application.get_env(:synapsis_agent, :filesystem_node),
            cache_scope: scope
          ],
          web_timeout: 5_000,
          web_scope: scope,
          session_binding: binding
        }

        native_authority = %{
          authority
          | grants: @names,
            tool_revisions: Map.take(authority.tool_revisions, @names)
        }

        case Codex.profile(:service_compat, native_context, native_authority, tools: @names) do
          {:ok, bundle} -> {:ok, [bundle]}
          error -> error
        end
      else
        false -> {:error, Error.new(:forbidden, "Fetch exceeds the parent authority ceiling")}
        error -> error
      end
    else
      {:ok, []}
    end
  end

  def classify(
        %{
          tool_name: "web::fetch",
          backend: Backend,
          backend_context: %{family: :service, context: %{web_scope: scope} = context}
        } = descriptor,
        identity,
        invocation
      ) do
    with true <-
           scope.identity === identity and invocation[:tool_name] === descriptor.tool_name and
             invocation[:tool_revision] === descriptor.tool_revision,
         :ok <- Synapsis.Agent.Tools.CatalogBinding.descriptor(descriptor, identity, invocation),
         {:ok, agent, hosts} <- configuration(scope.agent_name),
         true <-
           agent.id === scope.agent_id and fingerprint(hosts) === scope.hosts_fingerprint and
             hosts === context.web_allowed_hosts,
         {:ok, %{"url" => url}} <-
           InputSchema.validate(descriptor.schema, invocation[:arguments]),
         {:ok, resource} <- resource(url, hosts) do
      {:ok, %{action: "web.fetch", resource: resource}}
    else
      false -> {:error, :web_configuration_changed}
      error -> error
    end
  end

  def classify(_, _, _), do: {:error, :unsupported_classification}

  defp fingerprint(hosts), do: :crypto.hash(:sha256, :erlang.term_to_binary(hosts))

  # Backplane Web keeps its URL validation private; mirror its finite URL shape
  # for classification, while the original native service validates execution.
  defp resource(url, hosts) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host in hosts and
         is_nil(uri.userinfo) and is_nil(uri.fragment) do
      {:ok, "web:" <> URI.to_string(uri)}
    else
      {:error, Error.new(:forbidden, "Fetch requires an authorized absolute HTTP resource URL")}
    end
  end

  defp configuration(name) when is_binary(name) do
    with %AgentConfig{enabled: true, config: config} = agent <- AgentConfigs.get_by_name(name),
         hosts when is_list(hosts) and hosts != [] <- config["web_allowed_hosts"],
         true <- Enum.all?(hosts, &valid_host?/1) do
      {:ok, agent, hosts |> Enum.map(&String.downcase/1) |> Enum.uniq() |> Enum.sort()}
    else
      _ -> unavailable()
    end
  end

  defp configuration(_), do: unavailable()

  defp valid_host?(host) when is_binary(host) and byte_size(host) in 1..253 do
    String.valid?(host) and String.trim(host) == host and
      not String.match?(host, ~r/[\s\x00-\x1f\x7f\/:@?#*]/u) and
      match?(
        %URI{host: ^host, userinfo: nil, path: nil, query: nil, fragment: nil},
        URI.parse("https://" <> host)
      )
  end

  defp valid_host?(_), do: false

  defp unavailable do
    {:error,
     Error.new(
       :unsupported_capability,
       "web::fetch requires an enabled Agent with a nonempty config.web_allowed_hosts list of host names"
     )}
  end
end
