defmodule Synapsis.Memory.CacheTest do
  use ExUnit.Case, async: true

  alias Synapsis.Memory.Cache

  setup do
    prefix = "test_#{System.unique_integer([:positive])}"
    {:ok, prefix: prefix}
  end

  describe "get/put" do
    test "returns :miss for missing key", %{prefix: prefix} do
      assert Cache.get("#{prefix}:missing") == :miss
    end

    test "stores and retrieves a value", %{prefix: prefix} do
      key = "#{prefix}:hello"
      Cache.put(key, "world")
      assert Cache.get(key) == {:ok, "world"}
    end

    test "stores complex values", %{prefix: prefix} do
      key = "#{prefix}:complex"
      value = [%{title: "test", summary: "data"}]
      Cache.put(key, value)
      assert Cache.get(key) == {:ok, value}
    end

    test "overwrites existing value", %{prefix: prefix} do
      key = "#{prefix}:overwrite"
      Cache.put(key, "first")
      Cache.put(key, "second")
      assert Cache.get(key) == {:ok, "second"}
    end

    test "respects TTL expiry", %{prefix: prefix} do
      key = "#{prefix}:ttl"
      Cache.put(key, "expires", 1)
      assert Cache.get(key) == {:ok, "expires"}

      Process.sleep(10)
      assert Cache.get(key) == :miss
    end
  end

  describe "clear/0" do
    test "removes all cached entries", %{prefix: prefix} do
      Cache.put("#{prefix}:a", 1)
      Cache.put("#{prefix}:b", 2)

      Cache.clear()

      assert Cache.get("#{prefix}:a") == :miss
      assert Cache.get("#{prefix}:b") == :miss
    end
  end
end
