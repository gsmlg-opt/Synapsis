defmodule Synapsis.MCPConfigTest do
  use Synapsis.DataCase, async: true

  alias Synapsis.MCPConfig

  describe "changeset/2" do
    test "valid with required fields" do
      changeset =
        MCPConfig.changeset(%MCPConfig{}, %{
          name: "filesystem",
          transport: "stdio"
        })

      assert changeset.valid?
    end

    test "requires name" do
      changeset = MCPConfig.changeset(%MCPConfig{}, %{transport: "stdio"})
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "transport defaults to stdio when omitted" do
      changeset = MCPConfig.changeset(%MCPConfig{}, %{name: "myserver"})
      # transport defaults to "stdio" so the changeset is still valid
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :transport) == "stdio"
    end

    test "rejects invalid transport" do
      changeset =
        MCPConfig.changeset(%MCPConfig{}, %{name: "myserver", transport: "websocket"})

      refute changeset.valid?
      assert %{transport: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts stdio transport" do
      {:ok, config} =
        %MCPConfig{}
        |> MCPConfig.changeset(%{
          name: "stdio-server",
          transport: "stdio",
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem"]
        })
        |> Repo.insert()

      assert config.transport == "stdio"
      assert config.args == ["-y", "@modelcontextprotocol/server-filesystem"]
    end

    test "accepts sse transport" do
      {:ok, config} =
        %MCPConfig{}
        |> MCPConfig.changeset(%{
          name: "sse-server",
          transport: "sse",
          url: "http://localhost:3000/mcp"
        })
        |> Repo.insert()

      assert config.transport == "sse"
      assert config.url == "http://localhost:3000/mcp"
    end

    test "defaults auto_connect to false" do
      {:ok, config} =
        %MCPConfig{}
        |> MCPConfig.changeset(%{name: "no-auto", transport: "stdio"})
        |> Repo.insert()

      assert config.auto_connect == false
    end

    test "stores env map" do
      {:ok, config} =
        %MCPConfig{}
        |> MCPConfig.changeset(%{
          name: "env-test",
          transport: "stdio",
          env: %{"API_KEY" => "secret", "DEBUG" => "1"}
        })
        |> Repo.insert()

      assert config.env["API_KEY"] == "secret"
    end

    test "enforces unique name constraint" do
      {:ok, _} =
        %MCPConfig{}
        |> MCPConfig.changeset(%{name: "dup-mcp", transport: "stdio"})
        |> Repo.insert()

      assert {:error, changeset} =
               %MCPConfig{}
               |> MCPConfig.changeset(%{name: "dup-mcp", transport: "sse"})
               |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
