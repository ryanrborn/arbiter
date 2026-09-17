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

  Rotation is Cloak's native two-cipher scheme, driven by two **optional**
  env vars: `ARBITER_CLOAK_KEY_OLD` and `ARBITER_CLOAK_KEY_GENERATION`.

  The `:default` cipher's tag is `"AES.GCM.V<generation>"`, where
  `<generation>` defaults to `1` — so an install that has never rotated
  needs neither env var, and keeps writing/reading the same tag
  (`"AES.GCM.V1"`) it always has. **Only bump `ARBITER_CLOAK_KEY_GENERATION`
  as a permanent step of actually completing a rotation** — bumping it
  without also migrating the data (see below) makes existing ciphertext
  (tagged with the previous generation) undecryptable, since nothing
  registers a cipher for that tag anymore.

  To rotate from generation N to N+1:

    1. Set `ARBITER_CLOAK_KEY` to the new key, `ARBITER_CLOAK_KEY_OLD` to the
       key that generation N used, and bump `ARBITER_CLOAK_KEY_GENERATION`
       to N+1 — all three at once, in the same deploy. `init/1` now
       registers `:default` (tag `V<N+1>`, the new key) and `:retired` (tag
       `V<N>`, the old key, decrypt-only), so both old and new ciphertext
       keep working through the window.
    2. Run `Arbiter.Vault.Rotation.sweep!/0` (via `mix
       arbiter.rotate_cloak_key --sweep`) to re-encrypt every row onto the
       new cipher, and `verify/0` (`--verify`) to confirm zero rows remain
       tagged `V<N>`.
    3. Remove `ARBITER_CLOAK_KEY_OLD` and redeploy — leave
       `ARBITER_CLOAK_KEY_GENERATION` at N+1 permanently. The retired cipher
       drops out of `init/1`; the current generation's tag doesn't change,
       so the now fully-migrated data keeps decrypting.

  See `docs/cloak-key-rotation.md` for the full runbook and
  `Arbiter.Vault.Rotation` for the sweep/verify task this drives.
  """

  use Cloak.Vault, otp_app: :arbiter

  @impl GenServer
  def init(config) do
    generation = generation!()

    ciphers =
      [
        {:default, {Cloak.Ciphers.AES.GCM, tag: tag_for(generation), key: key!(), iv_length: 12}}
      ] ++ retired_cipher(generation)

    {:ok, Keyword.put(config, :ciphers, ciphers)}
  end

  @doc "Tag stamped on ciphertext written by the current (`:default`) cipher."
  @spec current_tag() :: String.t()
  def current_tag, do: tag_for(generation!())

  @doc """
  Tag stamped on ciphertext written by the previous generation's cipher —
  only meaningful (i.e. actually registered as `:retired`) while
  `ARBITER_CLOAK_KEY_OLD` is configured.
  """
  @spec retired_tag() :: String.t()
  def retired_tag, do: tag_for(generation!() - 1)

  defp tag_for(generation), do: "AES.GCM.V#{generation}"

  defp retired_cipher(generation) do
    case old_key() do
      nil ->
        []

      key ->
        [
          {:retired,
           {Cloak.Ciphers.AES.GCM, tag: tag_for(generation - 1), key: key, iv_length: 12}}
        ]
    end
  end

  @doc """
  Resolve the current key generation (`1` unless a rotation has bumped it),
  raising a clear error when malformed.

  Resolution order:

    1. `ARBITER_CLOAK_KEY_GENERATION` environment variable (a positive integer).
    2. `config :arbiter, Arbiter.Vault, key_generation: <integer>` — test-only
       fallback.
    3. `1`, when neither is set.
  """
  @spec generation!() :: pos_integer()
  def generation! do
    case raw_generation() do
      nil ->
        1

      raw ->
        case Integer.parse(raw) do
          {n, ""} when n >= 1 ->
            n

          _ ->
            raise "ARBITER_CLOAK_KEY_GENERATION must be a positive integer, got: #{inspect(raw)}"
        end
    end
  end

  defp raw_generation do
    case System.get_env("ARBITER_CLOAK_KEY_GENERATION") do
      v when is_binary(v) and v != "" ->
        v

      _ ->
        case Application.get_env(:arbiter, __MODULE__)[:key_generation] do
          nil -> nil
          v -> to_string(v)
        end
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
