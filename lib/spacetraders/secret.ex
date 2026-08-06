defmodule SpaceTraders.Secret do
  @moduledoc """
  An `Ecto.Type` that encrypts string values at rest using AES-256-GCM.

  Used for game secrets (per-operator AccountTokens and per-agent AgentTokens)
  so a leaked database never exposes credentials in plaintext (ADR 0006). The
  field reads as the plaintext in memory; the column stores a base64-encoded
  `iv <> tag <> ciphertext` blob.

  The key is read from `config :spacetraders, SpaceTraders.Secret, key:` — a
  32-byte binary. Dev/test use a committed development key; production reads it
  from the `ENCRYPTION_KEY` environment variable (base64).
  """

  @behaviour Ecto.Type

  @iv_size 12
  @tag_size 16

  @impl true
  def type, do: :string

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_), do: :error

  @impl true
  def load(ciphertext) when is_binary(ciphertext) do
    {:ok, decrypt(ciphertext)}
  end

  @impl true
  def dump(nil), do: {:ok, nil}
  def dump(plaintext) when is_binary(plaintext), do: {:ok, encrypt(plaintext)}
  def dump(_), do: :error

  @impl true
  def embed_as(_format), do: :dump

  @impl true
  def equal?(left, right), do: left == right

  defp encrypt(plaintext) do
    iv = :crypto.strong_rand_bytes(@iv_size)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, "", true)
    Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt(ciphertext) do
    case Base.decode64(ciphertext) do
      {:ok, <<iv::binary-size(@iv_size), tag::binary-size(@tag_size), payload::binary>>} ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, payload, "", tag, false) do
          plaintext when is_binary(plaintext) -> plaintext
          :error -> raise "SpaceTraders.Secret: failed to decrypt value (wrong key?)"
        end

      _ ->
        raise "SpaceTraders.Secret: malformed ciphertext in database"
    end
  end

  defp key do
    Application.get_env(:spacetraders, __MODULE__, [])
    |> Keyword.fetch!(:key)
  end
end
