defmodule Arbiter.Vault do
  @moduledoc """
  Cloak vault used to encrypt sensitive `Workspace` attributes at rest
  (tracker/merger secrets — see `Arbiter.Tasks.Workspace` and `ash_cloak`).

  The AES-256-GCM key is read at **runtime** from the `ARBITER_CLOAK_KEY`
  environment variable, which must be a Base64-encoded 32-byte value:

      ARBITER_CLOAK_KEY="$(openssl rand -base64 32)"

  The vault is a `GenServer` in the supervision tree; `init/1` resolves the key
  via `key!/0` and **raises** when it is missing or malformed, so the server
  refuses to boot rather than start with no encryption key. Tests inject a key
  through `config :arbiter, Arbiter.Vault, key: <base64>` (see `config/test.exs`)
  so the suite does not depend on a real environment variable.

  Rotating the key is intentionally out of scope (see the task's "Out of
  scope"); a rotation runbook is a separate concern.
  """

  use Cloak.Vault, otp_app: :arbiter

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: key!(), iv_length: 12}
      )

    {:ok, config}
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
        decode!(raw)
    end
  end

  defp raw_key do
    case System.get_env("ARBITER_CLOAK_KEY") do
      v when is_binary(v) and v != "" -> v
      _ -> Application.get_env(:arbiter, __MODULE__)[:key]
    end
  end

  defp decode!(raw) do
    case Base.decode64(String.trim(raw)) do
      {:ok, key} when byte_size(key) == 32 ->
        key

      {:ok, key} ->
        raise "ARBITER_CLOAK_KEY must decode to 32 bytes (a 256-bit AES key), " <>
                "got #{byte_size(key)} bytes. Generate one with: openssl rand -base64 32"

      :error ->
        raise "ARBITER_CLOAK_KEY must be valid Base64. Generate one with: openssl rand -base64 32"
    end
  end
end
