defmodule Synapsis.Tool.ExecutorLifetimeTest do
  use ExUnit.Case, async: false

  alias Synapsis.Tool.{Gateway, Registry}

  defmodule BlockingTool do
    use Synapsis.Tool
    def name, do: "executor-lifetime-fixture"
    def description, do: "Inert lifetime fixture"
    def parameters, do: %{"type" => "object", "properties" => %{}}
    def permission_level, do: :read

    def execute(_, context) do
      send(context.test_pid, {:tool_started, self()})

      receive do
        :finish -> {:ok, "done"}
      after
        5_000 -> {:error, :fixture_deadline}
      end
    end
  end

  setup do
    name = "executor-lifetime-#{Ecto.UUID.generate()}"
    :ok = Registry.register_module(name, BlockingTool)
    on_exit(fn -> Registry.unregister(name) end)
    %{name: name, supervisor: start_supervised!(Task.Supervisor)}
  end

  for linked <- [false, true] do
    test "owner death with tool_task_link=#{linked}", ctx do
      context = %{
        run_id: Ecto.UUID.generate(),
        test_pid: self(),
        tool_profile: :coding,
        tool_timeout_ms: 4_000,
        tool_max_retries: 0
      }

      context = if unquote(linked), do: Map.put(context, :tool_task_link, true), else: context

      owner =
        Task.Supervisor.async_nolink(ctx.supervisor, fn ->
          Gateway.execute(ctx.name, %{}, context)
        end)

      assert_receive {:tool_started, tool}, 2_000
      ref = Process.monitor(tool)
      Task.shutdown(owner, :brutal_kill)

      if unquote(linked) do
        assert_receive {:DOWN, ^ref, :process, ^tool, _}, 2_000
      else
        refute_receive {:DOWN, ^ref, :process, ^tool, _}, 50
        assert Process.alive?(tool)
        send(tool, :finish)
        assert_receive {:DOWN, ^ref, :process, ^tool, :normal}, 2_000
      end
    end
  end
end
