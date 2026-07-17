defmodule Arbiter.Tasks.Workspace.Changes.MergeWorkerEnv do
  @moduledoc """
  Applies **merge-patch** semantics to a workspace's user-defined worker env
  vars, keeping the encrypted value store (`worker_env`) and the public
  names+flags metadata (`worker_env_meta`) in lockstep.

  The `:create` / `:update` actions accept a `worker_env` argument keyed by env
  var name, where each value is one of:

    * `%{"value" => string, "secret" => boolean}` — set/overwrite the value and
      the secret flag (`"secret"` optional, defaults to the existing flag or
      `false`);
    * `%{"secret" => boolean}` (no `"value"`) — toggle the secret flag of an
      **existing** key without touching its value;
    * `nil` — remove the key from both the value store and the metadata;
    * keys absent from the argument are left untouched.

  Env var names must match `#{inspect(~r/^[A-Za-z_][A-Za-z0-9_]*$/)}`. Values
  must be strings; the secret flag must be a boolean.

  Values are written through `AshCloak.encrypt_and_set/3` (AES-256-GCM, into the
  `encrypted_worker_env` column); the metadata — names + flags only, never
  values — is written to the plain public `worker_env_meta` attribute. Mirrors
  `Arbiter.Tasks.Workspace.Changes.MergeSecrets`, extended with the per-key
  secret flag.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Arbiter.Tasks.Workspace

  @name_re ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.fetch_argument(changeset, :worker_env) do
      {:ok, incoming} when is_map(incoming) ->
        apply_patch(changeset, incoming)

      {:ok, nil} ->
        # Explicit null patch: no-op (use per-key nil values to remove keys).
        changeset

      {:ok, _other} ->
        Changeset.add_error(changeset,
          field: :worker_env,
          message: "must be a map of env var name to a per-key map or null"
        )

      :error ->
        changeset
    end
  end

  defp apply_patch(changeset, incoming) do
    existing_values = existing_values(changeset)
    existing_meta = existing_meta(changeset)

    case merge(incoming, existing_values, existing_meta) do
      {:ok, values, meta} ->
        changeset
        |> AshCloak.encrypt_and_set(:worker_env, values)
        |> Changeset.force_change_attribute(:worker_env_meta, meta)

      {:error, message} ->
        Changeset.add_error(changeset, field: :worker_env, message: message)
    end
  end

  # Fold the incoming patch over the existing {values, meta}, or halt on the
  # first invalid entry.
  defp merge(incoming, values, meta) do
    Enum.reduce_while(incoming, {:ok, values, meta}, fn {key, patch}, {:ok, v, m} ->
      case apply_key(key, patch, v, m) do
        {:ok, v2, m2} -> {:cont, {:ok, v2, m2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp apply_key(key, _patch, _v, _m) when not is_binary(key),
    do: {:error, "env var names must be strings"}

  defp apply_key(key, patch, v, m) do
    cond do
      not Regex.match?(@name_re, key) ->
        {:error, "invalid env var name #{inspect(key)} (must match [A-Za-z_][A-Za-z0-9_]*)"}

      is_nil(patch) ->
        {:ok, Map.delete(v, key), Map.delete(m, key)}

      is_map(patch) ->
        apply_map_patch(key, patch, v, m)

      true ->
        {:error, "worker env #{inspect(key)} must be a map or null"}
    end
  end

  defp apply_map_patch(key, patch, v, m) do
    with {:ok, value} <- fetch_value(key, patch, v),
         {:ok, secret?} <- fetch_secret(patch, Map.get(m, key)) do
      {:ok, Map.put(v, key, value), Map.put(m, key, %{"secret" => secret?})}
    end
  end

  # Resolve the value for `key`: an explicit string sets it; an absent "value"
  # preserves the existing value (metadata-only patch) — but only if the key
  # already exists, since we cannot store metadata for a value we don't have.
  defp fetch_value(key, patch, existing_values) do
    case Map.fetch(patch, "value") do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _non_string} ->
        {:error, "worker env #{inspect(key)} value must be a string"}

      :error ->
        case Map.fetch(existing_values, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, "worker env #{inspect(key)} has no value; provide \"value\""}
        end
    end
  end

  # Resolve the secret flag: an explicit boolean sets it; absent preserves this
  # key's existing flag, defaulting to false for a brand-new key.
  defp fetch_secret(patch, existing_key_meta) do
    case Map.fetch(patch, "secret") do
      {:ok, flag} when is_boolean(flag) -> {:ok, flag}
      {:ok, _bad} -> {:error, "\"secret\" must be a boolean"}
      :error -> {:ok, existing_secret?(existing_key_meta)}
    end
  end

  defp existing_secret?(%{"secret" => true}), do: true
  defp existing_secret?(_), do: false

  defp existing_values(%{data: %Workspace{} = data}), do: Workspace.worker_env_map(data)
  defp existing_values(_changeset), do: %{}

  defp existing_meta(%{data: %Workspace{} = data}), do: data.worker_env_meta || %{}
  defp existing_meta(_changeset), do: %{}
end
