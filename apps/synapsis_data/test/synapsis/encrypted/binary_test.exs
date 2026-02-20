defmodule Synapsis.Encrypted.BinaryTest do
  use ExUnit.Case, async: true

  alias Synapsis.Encrypted.Binary

  describe "cast/1" do
    test "casts nil" do
      assert {:ok, nil} = Binary.cast(nil)
    end

    test "casts binary" do
      assert {:ok, "hello"} = Binary.cast("hello")
    end

    test "rejects non-binary" do
      assert :error = Binary.cast(123)
    end
  end

  describe "dump/1 and load/1 round-trip" do
    test "encrypts and decrypts a string" do
      {:ok, encrypted} = Binary.dump("sk-ant-secret-key")
      assert is_binary(encrypted)
      assert encrypted != "sk-ant-secret-key"

      {:ok, decrypted} = Binary.load(encrypted)
      assert decrypted == "sk-ant-secret-key"
    end

    test "nil passes through dump" do
      assert {:ok, nil} = Binary.dump(nil)
    end

    test "nil passes through load" do
      assert {:ok, nil} = Binary.load(nil)
    end

    test "encrypted output differs each time due to random IV" do
      {:ok, enc1} = Binary.dump("same-value")
      {:ok, enc2} = Binary.dump("same-value")
      assert enc1 != enc2

      {:ok, dec1} = Binary.load(enc1)
      {:ok, dec2} = Binary.load(enc2)
      assert dec1 == dec2
    end

    test "handles empty string" do
      {:ok, encrypted} = Binary.dump("")
      {:ok, decrypted} = Binary.load(encrypted)
      assert decrypted == ""
    end

    test "handles long values" do
      long = String.duplicate("x", 10_000)
      {:ok, encrypted} = Binary.dump(long)
      {:ok, decrypted} = Binary.load(encrypted)
      assert decrypted == long
    end
  end

  describe "load/1 error cases" do
    test "returns error for truncated data" do
      assert :error = Binary.load("short")
    end

    test "returns error for corrupted data" do
      {:ok, encrypted} = Binary.dump("test")
      # Corrupt the ciphertext portion
      corrupted = binary_part(encrypted, 0, byte_size(encrypted) - 1) <> <<0>>
      assert :error = Binary.load(corrupted)
    end
  end

  describe "dump/1 error case" do
    test "rejects non-binary input" do
      assert :error = Binary.dump(12_345)
      assert :error = Binary.dump(:atom)
      assert :error = Binary.dump(["list"])
    end
  end

  describe "equal?/2" do
    test "nils are equal" do
      assert Binary.equal?(nil, nil)
    end

    test "same values are equal" do
      assert Binary.equal?("abc", "abc")
    end

    test "different values are not equal" do
      refute Binary.equal?("abc", "def")
    end
  end
end
