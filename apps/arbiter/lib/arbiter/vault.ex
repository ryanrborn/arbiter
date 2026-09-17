defmodule Arbiter.Vault do
  @moduledoc """
  Cloak vault used to encrypt sensitive `Workspace` / `ProviderCredential`
  attributes at rest (see `ash_cloak` `cloak` blocks on those resources).

  The AES-256-GCM key is read at **runtime** from the `ARBITER_CLOAK_KEY`
  environment variable, which must be a Base64-encoded 32-byte value:

      ARBITER_CLOAK_KEY="$(openssl rand -base64 32)"

  The vault is a `GenServer` in the supervision tree; `init/1` resolves the key
  via `key!/0` and **raises** when it is missing or malformed, so the server
  refuses to boot rather than start with no encryption key. Tests inject a key
  through `config :arbiter, Arbiter.Vault, key: <base64>` (see `config/test.exs`)
  so the suite does not depend on a real environment variable.

  ## Key rotation

  Rotation is Cloak's native two-cipher scheme, driven by a second,
  **optional** env var: `ARBITER_CLOAK_KEY_OLD`.

    * New ciphertext is always written with the `:default` cipher (tag
      `"AES.GCM.V2"`, key from `ARBITER_CLOAK_KEY`).
    * When `ARBITER_CLOAK_KEY_OLD` is set, a second cipher (tag
      `"AES.GCM.V1"`) is registered **decrypt-only** so rows still encrypted
      under the previous key keep working during the rotation window. Cloak
      dispatches decryption by matching the tag embedded in the ciphertext,
      not by key, so the two tags must differ.
    * Once `Arbiter.Vault.Rotation.verify/0` confirms no rows remain tagged
      `"AES.GCM.V1"`, remove `ARBITER_CLOAK_KEY_OLD` from the environment and
      redeploy — the retired cipher then drops out of `init/1` automatically.

  See `docs/cloak-key-rotation.md` for the full runbook and
  `Arbiter.Vault.Rotation` for the sweep/verify task this drives.
  """

  use Cloak.Vault, otp_app: :arbiter

  @current_tag "AES.GCM.V2"
  @retired_tag "AES.GCM.V1"

  @impl GenServer
  def init(config) do
    ciphers =
      [{:default, {Cloak.Ciphers.AES.GCM, tag: @current_tag, key: key!(), iv_length: 12}}] ++
        retired_cipher()

    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end

  @doc "Tag stamped on ciphertext written by the current (`:default`) cipher."
  @spec current_tag() :: String.t()
  def current_tag, do: @current_tag

  @doc """
  Tag stamped on ciphertext written by the retired, decrypt-only cipher —
  only meaningful while `ARBITER_CLOAK_KEY_OLD` is configured.
  """
  @spec retired_tag() :: String.t()
  def retired_tag, do: @retired_tag

  defp retired_cipher do
    case old_key() do
      nil -> []
      key -> [{:retired, {Cloak.Ciphers.AES.GCM, tag: @retired_tag, key: key, iv_length: 12}}]
    end
  end

  @doc """
  Resolve the raw 32-byte AES key, raising a clear error when unavailable.

  Resolution order:

    1. `ARBITER_CLOAK_KEY` environment variable (Base64, 32 bytes once decoded).
    2. `config :arbiter, Arbiter.Vault, key: <base64>` — a config fallback used
       only by the test suite.

  Raises `RuntimeError` with an actionable message when the key is missing or
  does not decode to exactly 32 bytes.
  """
  @spec key!() :: binary()
  def key! do
    case raw_key() do
      nil ->
        raise """
        ARBITER_CLOAK_KEY is not set.

        Arbiter encrypts workspace secrets at rest and refuses to start without
        an encryption key. Generate one and add it to your environment
        (.arbiter.env or ~/.arbiter/arbiter.env):

            ARBITER_CLOAK_KEY="$(openssl rand -base64 32)"
        """

      raw ->
        decode!(raw, "ARBITER_CLOAK_KEY")
    end
  end

  @doc """
  Resolve the raw 32-byte AES key for the retired (decrypt-only) cipher, or
  `nil` when no rotation is in progress.

  Resolution order mirrors `key!/0`:

    1. `ARBITER_CLOAK_KEY_OLD` environment variable.
    2. `config :arbiter, Arbiter.Vault, old_key: <base64>` — test-only fallback.

  Raises the same way `key!/0` does when the value is present but malformed —
  a rotation should fail loudly, not silently drop decrypt support for
  not-yet-migrated rows.
  """
  @spec old_key() :: binary() | nil
  def old_key do
    case raw_old_key() do
      nil -> nil
      raw -> decode!(raw, "ARBITER_CLOAK_KEY_OLD")
    end
  end

  defp raw_key do
    case System.get_env("ARBITER_CLOAK_KEY") do
      v when is_binary(v) and v != "" -> v
      _ -> Application.get_env(:arbiter, __MODULE__)[:key]
    end
  end

  defp raw_old_key do
    case System.get_env("ARBITER_CLOAK_KEY_OLD") do
      v when is_binary(v) and v != "" -> v
      _ -> Application.get_env(:arbiter, __MODULE__)[:old_key]
    end
  end

  defp decode!(raw, var_name) do
    case Base.decode64(String.trim(raw)) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      {:ok, key} ->
        raise "#{var_name} must decode to 32 bytes (a 256-bit AES key), " <>
                "got #{byte_size(key)} bytes. Generate one with: openssl rand -base64 32"

      :error ->
        raise "#{var_name} must be valid Base64. Generate one with: openssl rand -base64 32"
    end
  end
end
