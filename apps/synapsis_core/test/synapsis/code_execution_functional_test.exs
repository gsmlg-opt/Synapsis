defmodule Synapsis.CodeExecutionFunctionalTest do
  use ExUnit.Case, async: false

  alias Synapsis.CodeExecution

  setup do
    fixture = Gaoxy.Test.open()
    on_exit(fn -> Gaoxy.Test.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "completed identical tasks remain independent remote calls", %{fixture: fixture} do
    owner = self()

    Gaoxy.Test.stub(fixture, "POST", "/v1/responses", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "output" => [
            %{"type" => "code_interpreter_call"},
            %{"type" => "output_text", "text" => "3"}
          ]
        })
      )
    end)

    config = %{
      api_key: "ordinary-code-fixture-key",
      base_url: Gaoxy.Test.url(fixture, "/v1"),
      timeout_ms: 5_000
    }

    assert {:ok, first} = CodeExecution.execute(config, %{"task" => " Sum 1+2 "})
    assert {:ok, second} = CodeExecution.execute(config, %{"task" => "Sum 1+2"})
    assert Map.delete(first, "tookMs") == Map.delete(second, "tookMs")
    assert first["usedCodeExecution"] == true
    assert first["content"] == "3"
    assert_receive {:request, body}
    assert_receive {:request, ^body}
  end

  test "full positive result survives beyond the search text limit", %{fixture: fixture} do
    content = String.duplicate("😀", 12_000)

    Gaoxy.Test.stub(fixture, "POST", "/v1/responses", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"output_text" => content}))
    end)

    config = %{
      api_key: "ordinary-code-fixture-key",
      base_url: Gaoxy.Test.url(fixture, "/v1"),
      timeout_ms: 5_000
    }

    assert {:ok, result} =
             CodeExecution.execute(config, %{"task" => "Report supplied analysis"},
               result_limit: 1_000_000
             )

    assert result["content"] == content
    assert result["outputTypes"] == []
    assert result["usedCodeExecution"] == false

    assert Enum.sort(Map.keys(result)) ==
             Enum.sort(
               ~w(task provider model tookMs content citations usedCodeExecution outputTypes)
             )
  end
end
