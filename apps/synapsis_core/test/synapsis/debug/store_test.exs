defmodule Synapsis.Debug.StoreTest do
  use ExUnit.Case, async: false

  alias Synapsis.Debug.Store

  setup do
    # Clear all entries before each test via the GenServer API
    # (ETS table is :protected, only the owning process can write)
    for session <- ~w(sess-1 sess-2 sess-3 sess-list sess-a sess-b sess-clear sess-keep sess-delete sess-orphan sess-merge) do
      Store.clear_entries(session)
    end

    :ok
  end

  describe "put_request/2" do
    test "inserts entry keyed by {session_id, request_id}" do
      request = %{
        request_id: "req-1",
        method: :post,
        url: "https://api.anthropic.com/v1/messages",
        headers: [{"content-type", "application/json"}],
        body: ~s({"model":"claude"}),
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        timestamp: DateTime.utc_now()
      }

      assert true == Store.put_request("sess-1", request)

      entries = Store.list_entries("sess-1")
      assert length(entries) == 1
      [entry] = entries
      assert entry.request_id == "req-1"
      assert entry.method == :post
      assert entry.status == nil
    end

    test "response fields are nil on initial insert" do
      request = %{
        request_id: "req-2",
        method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        headers: [],
        body: "{}",
        provider: :openai,
        model: "gpt-4.1",
        timestamp: DateTime.utc_now()
      }

      Store.put_request("sess-2", request)
      [entry] = Store.list_entries("sess-2")

      assert entry.status == nil
      assert entry.response_body == nil
      assert entry.complete == nil
      assert entry.duration_ms == nil
    end
  end

  describe "put_response/2" do
    test "merges response into existing request entry" do
      request = %{
        request_id: "req-3",
        method: :post,
        url: "https://api.anthropic.com/v1/messages",
        headers: [],
        body: "{}",
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        timestamp: DateTime.utc_now()
      }

      Store.put_request("sess-3", request)

      response = %{
        request_id: "req-3",
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s({"content":[]}),
        complete: true,
        error: nil,
        duration_ms: 3400,
        timestamp: DateTime.utc_now()
      }

      assert true == Store.put_response("sess-3", response)

      [entry] = Store.list_entries("sess-3")
      assert entry.request_id == "req-3"
      assert entry.method == :post
      assert entry.status == 200
      assert entry.complete == true
      assert entry.duration_ms == 3400
    end

    test "handles response arriving without prior request" do
      response = %{
        request_id: "req-orphan",
        status: 200,
        headers: [],
        body: "{}",
        complete: true,
        error: nil,
        duration_ms: 100,
        timestamp: DateTime.utc_now()
      }

      Store.put_response("sess-orphan", response)
      entries = Store.list_entries("sess-orphan")
      assert length(entries) == 1
    end

    test "preserves request fields when merging response" do
      now = DateTime.utc_now()

      Store.put_request("sess-merge", %{
        request_id: "req-merge",
        method: :post,
        url: "https://api.example.com/v1/messages",
        headers: [{"x-custom", "value"}],
        body: ~s({"prompt":"hello"}),
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        timestamp: now
      })

      Store.put_response("sess-merge", %{
        request_id: "req-merge",
        status: 200,
        headers: [],
        body: ~s({"reply":"hi"}),
        complete: true,
        error: nil,
        duration_ms: 500,
        timestamp: DateTime.utc_now()
      })

      [entry] = Store.list_entries("sess-merge")
      # Request fields preserved
      assert entry.method == :post
      assert entry.url == "https://api.example.com/v1/messages"
      assert entry.provider == :anthropic
      # Response fields merged
      assert entry.status == 200
      assert entry.duration_ms == 500
    end
  end

  describe "list_entries/1" do
    test "returns all entries for session sorted by timestamp" do
      for i <- 1..3 do
        Store.put_request("sess-list", %{
          request_id: "req-#{i}",
          method: :post,
          url: "https://api.example.com",
          headers: [],
          body: "{}",
          provider: :anthropic,
          model: "claude",
          timestamp: DateTime.add(DateTime.utc_now(), i, :second)
        })
      end

      entries = Store.list_entries("sess-list")
      assert length(entries) == 3

      # Verify sorted by timestamp
      timestamps = Enum.map(entries, & &1[:request_timestamp])
      assert timestamps == Enum.sort(timestamps, DateTime)
    end

    test "returns empty list for unknown session" do
      assert [] = Store.list_entries("nonexistent")
    end

    test "does not return entries from other sessions" do
      Store.put_request("sess-a", %{
        request_id: "req-a",
        method: :post,
        url: "https://api.example.com",
        headers: [],
        body: "{}",
        provider: :anthropic,
        model: "claude",
        timestamp: DateTime.utc_now()
      })

      Store.put_request("sess-b", %{
        request_id: "req-b",
        method: :post,
        url: "https://api.example.com",
        headers: [],
        body: "{}",
        provider: :openai,
        model: "gpt-4.1",
        timestamp: DateTime.utc_now()
      })

      entries_a = Store.list_entries("sess-a")
      assert length(entries_a) == 1
      assert hd(entries_a).request_id == "req-a"
    end
  end

  describe "clear_entries/1" do
    test "removes all entries for session" do
      for i <- 1..3 do
        Store.put_request("sess-clear", %{
          request_id: "req-#{i}",
          method: :post,
          url: "https://api.example.com",
          headers: [],
          body: "{}",
          provider: :anthropic,
          model: "claude",
          timestamp: DateTime.utc_now()
        })
      end

      count = Store.clear_entries("sess-clear")
      assert count == 3
      assert [] = Store.list_entries("sess-clear")
    end

    test "does not affect other sessions" do
      Store.put_request("sess-keep", %{
        request_id: "req-keep",
        method: :post,
        url: "https://api.example.com",
        headers: [],
        body: "{}",
        provider: :anthropic,
        model: "claude",
        timestamp: DateTime.utc_now()
      })

      Store.put_request("sess-delete", %{
        request_id: "req-del",
        method: :post,
        url: "https://api.example.com",
        headers: [],
        body: "{}",
        provider: :anthropic,
        model: "claude",
        timestamp: DateTime.utc_now()
      })

      Store.clear_entries("sess-delete")
      assert length(Store.list_entries("sess-keep")) == 1
      assert [] = Store.list_entries("sess-delete")
    end

    test "returns count of deleted entries" do
      assert 0 = Store.clear_entries("nonexistent")
    end
  end
end
