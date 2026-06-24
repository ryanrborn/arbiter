defmodule Arbiter.Agents.CredentialsRef do
  @moduledoc """
  Resolves a `credentials_ref` string into a concrete secret value.

  `credentials_ref` is a small DSL shared by every tracker / merger / agent
  adapter config. Historically only two forms existed:

    * `"env:NAME"` — looks up `System.get_env("NAME")`.
    * a bare string — treated as a literal token (discouraged outside tests).

  This module adds a third form:

    * `"secret:KEY"` — looks up `KEY` in the active workspace's encrypted
      `secrets` map (stored at rest via `ash_cloak`, see `Arbiter.Vault`).

  ## How secrets reach the resolver

  Each adapter stashes its active per-process config in the process dictionary
  via `Config.put_active(workspace)`. To keep `secret:` resolution working
  through that same seam — including the snapshot/restore (`with_active`)
  pattern — the workspace's decrypted secrets are **embedded into that stashed
  config map** under a private atom key (`embed_secrets/2`), and read back here
  via `secrets/1`. Embedding (rather than a separate process key) means secrets
  travel with the config snapshot automatically, so nested `with_active` blocks
  restore the correct secrets.

  Raw-map callers (tests that call `put_active(%{...})` with no workspace)
  simply carry no embedded secrets, so a `"secret:KEY"` ref resolves to
  `{:secret_not_found, key}`.
  """

  alias Arbiter.Tasks.Workspace

  @secrets_key :__arbiter_secrets__

  @typedoc """
  The outcome of resolving a ref:

    * `{:ok, value}` — resolved to a non-empty string.
    * `{:env_unset, name}` — an `env:` ref whose variable is unset/empty.
    * `{:secret_not_found, key}` — a `secret:` ref with no matching workspace secret.
    * `:missing` — no ref configured (nil / empty / non-string).
  """
  @type result ::
          {:ok, String.t()}
          | {:env_unset, String.t()}
          | {:secret_not_found, String.t()}
          | :missing

  @doc """
  Embed a workspace's `secrets` map into an adapter's raw config map so a later
  `resolve/2` against that map can resolve `"secret:KEY"` refs.

  Accepts a decrypted secrets map, `nil`, or an unloaded value (`%Ash.NotLoaded{}`)
  — anything that is not a map is treated as "no secrets".
  """
  @spec embed_secrets(map(), map() | nil | term()) :: map()
  def embed_secrets(raw, secrets) when is_map(raw) do
    Map.put(raw, @secrets_key, normalize(secrets))
  end

  @doc "Read the embedded secrets map back out of a raw config map (`%{}` if none)."
  @spec secrets(map()) :: %{optional(String.t()) => String.t()}
  def secrets(raw) when is_map(raw), do: Map.get(raw, @secrets_key) || %{}
  def secrets(_), do: %{}

  @doc """
  Resolve a `credentials_ref` against a raw config map (which may carry embedded
  secrets via `embed_secrets/2`).

  Returns a `t:result/0`. Callers map the tagged failures onto their own error
  shapes (trackers/mergers surface `:config_missing`; agents fall back to `nil`).
  """
  @spec resolve(term(), map()) :: result()
  def resolve(ref, raw \\ %{})

  def resolve("env:" <> name, _raw) do
    case System.get_env(name) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:env_unset, name}
    end
  end

  def resolve("secret:" <> key, raw) do
    case Map.get(secrets(raw), key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:secret_not_found, key}
    end
  end

  def resolve(literal, _raw) when is_binary(literal) and literal != "", do: {:ok, literal}
  def resolve(_other, _raw), do: :missing

  @doc """
  Resolve a `credentials_ref` directly against a `Workspace` struct.

  Convenience for callers that hold a loaded workspace rather than a stashed
  config map. Decrypts the workspace's secrets via `Workspace.secrets_map/1`.
  """
  @spec resolve_for_workspace(term(), Workspace.t()) :: result()
  def resolve_for_workspace(ref, %Workspace{} = workspace) do
    resolve(ref, embed_secrets(%{}, Workspace.secrets_map(workspace)))
  end

  defp normalize(secrets) when is_map(secrets) and not is_struct(secrets) do
    for {k, v} <- secrets, is_binary(k), is_binary(v), into: %{}, do: {k, v}
  end

  defp normalize(_), do: %{}
end
