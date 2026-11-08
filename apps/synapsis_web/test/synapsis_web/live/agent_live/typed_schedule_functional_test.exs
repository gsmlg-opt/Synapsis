defmodule SynapsisWeb.AgentLive.TypedScheduleFunctionalTest do
  use SynapsisWeb.ConnCase, async: false

  import SynapsisWeb.ReactFormHelpers

  alias SynapsisWeb.AgentLive.Daemon

  defmodule DaemonStub do
    def status do
      %{ready: true, active_run: nil, queued_count: 0, last_seen_at: nil, last_error: nil}
    end
  end

  defmodule EmptyStub do
    def list, do: []
    def list_enabled, do: []
    def list_recent(_opts), do: []
  end

  defmodule RoutinesStub do
    def list(nil), do: Application.fetch_env!(:synapsis_web, :typed_schedule_live).routines

    def create(attrs) do
      send(Application.fetch_env!(:synapsis_web, :typed_schedule_live).owner, {:created, attrs})
      {:ok, Map.put(attrs, "id", Ecto.UUID.generate())}
    end
  end

  setup do
    previous_deps = Application.get_env(:synapsis_web, Daemon, :missing)
    previous_state = Application.get_env(:synapsis_web, :typed_schedule_live, :missing)

    Application.put_env(:synapsis_web, Daemon,
      daemon: DaemonStub,
      runs: EmptyStub,
      routines: RoutinesStub,
      backplane: EmptyStub,
      agents: EmptyStub
    )

    schedules = [
      {"legacy", "0 2 * * *"},
      {"cron", %{"kind" => "cron", "expr" => "0 9 * * *", "tz" => "Asia/Kathmandu"}},
      {"at", %{"kind" => "at", "at" => "2027-01-01T00:00:00Z"}},
      {"every", %{"kind" => "every", "everyMs" => 1_500, "anchorMs" => 1_793_095_200_000}}
    ]

    Application.put_env(:synapsis_web, :typed_schedule_live, %{
      owner: self(),
      routines:
        Enum.map(schedules, fn {id, schedule} ->
          %{
            "id" => id,
            "source" => "routine",
            "name" => "Scheduled #{id}",
            "kind" => "schedule",
            "enabled" => true,
            "schedule" => schedule,
            "tool_profile" => "native_agent"
          }
        end)
    })

    on_exit(fn ->
      restore(Daemon, previous_deps)
      restore(:typed_schedule_live, previous_state)
    end)

    :ok
  end

  test "daemon renders legacy and typed cron at every schedules as readable labels", %{conn: conn} do
    assert {:ok, view, _html} = live_isolated(conn, Daemon)
    assert has_element?(view, "#routine-legacy", "0 2 * * *")
    assert has_element?(view, "#routine-cron", "0 9 * * *")
    assert has_element?(view, "#routine-cron", "Asia/Kathmandu")
    assert has_element?(view, "#routine-at", "2027-01-01T00:00:00Z")
    assert has_element?(view, "#routine-every", "1500")
  end

  test "existing creation form still submits a cron string", %{conn: conn} do
    assert {:ok, view, _html} = live_isolated(conn, Daemon)

    react_form_submit(view, "routine-create-form", %{
      "routine" => %{
        "name" => "Cron from form",
        "kind" => "schedule",
        "schedule" => " */15 * * * * ",
        "tool_profile" => "assistant_basic",
        "prompt" => "Inspect the scheduled work",
        "enabled" => "true"
      }
    })

    assert_receive {:created, %{"schedule" => "*/15 * * * *", "name" => "Cron from form"}}, 1_000
    assert render_async(view, 1_000) =~ "Routine created"
  end

  defp restore(key, :missing), do: Application.delete_env(:synapsis_web, key)
  defp restore(key, value), do: Application.put_env(:synapsis_web, key, value)
end
