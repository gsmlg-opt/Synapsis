defmodule Synapsis.Agent.Heartbeat.TemplatesTest do
  use Synapsis.Agent.DataCase

  alias Synapsis.Agent.Heartbeat.Templates
  alias Synapsis.{HeartbeatConfig, Repo}

  describe "seed_defaults/0" do
    test "creates morning-briefing template" do
      Templates.seed_defaults()

      config = Repo.get_by(HeartbeatConfig, name: "morning-briefing")
      assert config != nil
      assert config.schedule == "30 7 * * 1-5"
      assert config.prompt =~ "Summarize overnight"
    end

    test "creates stale-pr-check template" do
      Templates.seed_defaults()

      config = Repo.get_by(HeartbeatConfig, name: "stale-pr-check")
      assert config != nil
      assert config.schedule == "0 10 * * 1-5"
    end

    test "creates daily-summary template" do
      Templates.seed_defaults()

      config = Repo.get_by(HeartbeatConfig, name: "daily-summary")
      assert config != nil
      assert config.keep_history == true
    end

    test "all templates disabled by default" do
      Templates.seed_defaults()

      configs = Repo.all(HeartbeatConfig)
      assert Enum.all?(configs, &(&1.enabled == false))
    end

    test "idempotent" do
      Templates.seed_defaults()
      Templates.seed_defaults()

      configs = Repo.all(HeartbeatConfig)
      assert length(configs) == 3
    end
  end

  describe "defaults/0" do
    test "returns 3 template configurations" do
      assert length(Templates.defaults()) == 3
    end
  end
end
