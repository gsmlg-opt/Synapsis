defmodule Synapsis.Encrypted.Binary do
  @moduledoc "Custom Ecto type that transparently encrypts/decrypts binary data using AES-256-GCM."

  use Ecto.Type

  @aad "SynapsisEncryptedBinary"

  def type, do: :binary

  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  def dump(nil), do: {:ok, nil}

  def dump(value) when is_binary(value) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, @aad, true)

    {:ok, iv <> tag <> ciphertext}
  end

  def dump(_), do: :error

  def load(nil), do: {:ok, nil}

  def load(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = derive_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def load(_), do: :error

  def equal?(nil, nil), do: true
  def equal?(a, b), do: a == b

  defp derive_key do
    raw = Application.get_env(:synapsis_data, :encryption_key) || raise "encryption_key not set"
    :crypto.hash(:sha256, raw)
  end
end
