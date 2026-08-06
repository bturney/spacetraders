defmodule SpaceTraders.SecretTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Secret

  describe "type/0" do
    test "is a string column" do
      assert Secret.type() == :string
    end
  end

  describe "cast/1" do
    test "passes through nil and binaries" do
      assert {:ok, nil} = Secret.cast(nil)
      assert {:ok, "token"} = Secret.cast("token")
    end

    test "rejects non-binaries" do
      assert :error = Secret.cast(42)
    end
  end

  describe "dump/load round trip" do
    test "encrypts at rest and decrypts on load" do
      plaintext = "eyJhbGciOiJSUzI1NiJ9.example-token"

      {:ok, ciphertext} = Secret.dump(plaintext)

      assert is_binary(ciphertext)
      refute ciphertext == plaintext
      refute ciphertext =~ plaintext

      assert {:ok, ^plaintext} = Secret.load(ciphertext)
    end

    test "produces a unique ciphertext per value (random IV)" do
      {:ok, a} = Secret.dump("same")
      {:ok, b} = Secret.dump("same")
      refute a == b
    end

    test "nil dumps to nil" do
      assert {:ok, nil} = Secret.dump(nil)
    end
  end

  describe "decryption failures" do
    test "raises on malformed ciphertext" do
      assert_raise RuntimeError, ~r/malformed ciphertext/, fn ->
        Secret.load("not-base64!!")
      end
    end

    test "raises when the ciphertext is tampered with" do
      {:ok, ciphertext} = Secret.dump("secret-value")
      {:ok, binary} = Base.decode64(ciphertext)
      <<iv::binary-size(12), tag::binary-size(16), payload::binary>> = binary
      # Corrupt the authentication tag in place (length unchanged).
      tampered = Base.encode64(iv <> <<0>> <> binary_part(tag, 1, 15) <> payload)
      assert_raise RuntimeError, ~r/failed to decrypt/, fn -> Secret.load(tampered) end
    end
  end

  describe "equal?/2" do
    test "compares plaintext values" do
      assert Secret.equal?("a", "a")
      refute Secret.equal?("a", "b")
    end
  end
end
