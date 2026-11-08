defmodule Synapsis.Agent.Heartbeat.CronScheduleFunctionalTest do
  use ExUnit.Case, async: true

  alias Synapsis.Agent.Heartbeat.CronSchedule

  test "normalizes supported UTC aliases and trims named zones without changing the global database" do
    original_database = Calendar.get_time_zone_database()

    for timezone <- [nil, "", "  ", "UTC", "utc", " UTC ", "Etc/UTC"] do
      assert CronSchedule.normalize_timezone(timezone) == {:ok, "Etc/UTC"}
    end

    assert CronSchedule.normalize_timezone(" Asia/Kathmandu ") == {:ok, "Asia/Kathmandu"}
    assert Calendar.get_time_zone_database() == original_database
  end

  for {label, cron, timezone, now, first, following} <- [
        {"UTC exact minute is strictly future", "* * * * *", nil, "2026-10-27T10:00:00Z",
         "2026-10-27T10:01:00Z", "2026-10-27T10:02:00Z"},
        {"UTC partial minute", "* * * * *", "utc", "2026-10-27T10:00:40Z", "2026-10-27T10:01:00Z",
         "2026-10-27T10:02:00Z"},
        {"Shanghai local morning", "15 9 * * *", "Asia/Shanghai", "2026-10-27T00:00:00Z",
         "2026-10-27T01:15:00Z", "2026-10-28T01:15:00Z"},
        {"Kathmandu quarter-hour offset", "15 9 * * *", "Asia/Kathmandu", "2026-10-27T00:00:00Z",
         "2026-10-27T03:30:00Z", "2026-10-28T03:30:00Z"},
        {"Chatham summer quarter-hour offset", "15 9 * * *", "Pacific/Chatham",
         "2026-01-14T18:00:00Z", "2026-01-14T19:30:00Z", "2026-01-15T19:30:00Z"},
        {"New York chooses the first fold occurrence once", "30 1 * * *", "America/New_York",
         "2026-11-01T04:00:00Z", "2026-11-01T05:30:00Z", "2026-11-02T06:30:00Z"},
        {"New York after the first fold occurrence", "30 1 * * *", "America/New_York",
         "2026-11-01T05:45:00Z", "2026-11-02T06:30:00Z", "2026-11-03T06:30:00Z"},
        {"New York during the repeated interval", "30 1 * * *", "America/New_York",
         "2026-11-01T06:00:00Z", "2026-11-02T06:30:00Z", "2026-11-03T06:30:00Z"},
        {"Oslo skips a spring gap and rematches the following day", "30 2 * * *", "Europe/Oslo",
         "2026-03-28T23:00:00Z", "2026-03-30T00:30:00Z", "2026-03-31T00:30:00Z"},
        {"Lord Howe chooses the first thirty-minute fold occurrence once", "45 1 * * *",
         "Australia/Lord_Howe", "2026-04-04T14:00:00Z", "2026-04-04T14:45:00Z",
         "2026-04-05T15:15:00Z"},
        {"Lord Howe during its repeated interval", "45 1 * * *", "Australia/Lord_Howe",
         "2026-04-04T15:00:00Z", "2026-04-05T15:15:00Z", "2026-04-06T15:15:00Z"},
        {"annual Oslo schedule skips the spring-gap year", "30 2 29 3 *", "Europe/Oslo",
         "2026-03-28T23:00:00Z", "2027-03-29T00:30:00Z", "2028-03-29T00:30:00Z"}
      ] do
    @vector {cron, timezone, now, first, following}

    test "#{label}" do
      {cron, timezone, now_iso, first_iso, following_iso} = @vector
      {:ok, now, 0} = DateTime.from_iso8601(now_iso)
      original_database = Calendar.get_time_zone_database()

      assert {:ok, first} = CronSchedule.next_after(cron, timezone, now)
      assert %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = first
      assert DateTime.to_iso8601(first) == first_iso
      assert DateTime.compare(first, now) == :gt

      assert {:ok, following} = CronSchedule.next_after(cron, timezone, first)
      assert %DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = following
      assert DateTime.to_iso8601(following) == following_iso
      assert DateTime.compare(following, first) == :gt
      assert Calendar.get_time_zone_database() == original_database
    end
  end
end
