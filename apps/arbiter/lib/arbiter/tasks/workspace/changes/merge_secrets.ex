defmodule Arbiter.Tasks.Workspace.Changes.MergeSecrets do
  @moduledoc """
  Applies **merge-patch** semantics to a workspace's encrypted `secrets` map,
  then hands the merged map to `ash_cloak` for encryption.

  The `:create` / `:update` actions accept a `secrets` argument
  (`%{String.t() => String.t() | nil}`):

    * a key with a string value **sets/overwrites** that secret;
    * a key with a `nil` value **removes** that secret;
    * keys absent from the argument are **left untouched**;
    * omitting the `secrets` argument entirely leaves all existing secrets
      untouched (this change is a no-op).

  The merged full map is written through `AshCloak.encrypt_and_set/3`, which
  encrypts it into the `encrypted_secrets` column. We deliberately do **not**
  add `:secrets` to the action's `accept` list (which would let `ash_cloak`
  wire its own encrypt change): doing the merge here, in `change/3`, lets us
  fold the partial patch into the existing secrets before encryption.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Arbiter.Tasks.Workspace

  @impl true
  def change(changeset, _opts, _context) do
    case Changeset.fetch_argument(changeset, :secrets) do
      {:ok, incoming} when is_map(incoming) ->
        apply_patch(changeset, incoming)

      {:ok, nil} ->
        # Explicit null patch: no-op (use per-key nil values to remove secrets).
        changeset

      {:ok, _other} ->
        Changeset.add_error(changeset,
          field: :secrets,
          message: "must be a map of string keys to string (or null) values"
        )

      :error ->
        changeset
    end
  end

  defp apply_patch(changeset, incoming) do
    with :ok <- validate_shape(incoming) do
      merged = merge(existing_secrets(changeset), incoming)
      AshCloak.encrypt_and_set(changeset, :secrets, merged)
    else
      {:error, message} ->
        Changeset.add_error(changeset, field: :secrets, message: message)
    end
  end

  defp validate_shape(incoming) do
    Enum.reduce_while(incoming, :ok, fn {k, v}, :ok ->
      cond do
        not is_binary(k) ->
          {:halt, {:error, "secret keys must be strings"}}

        not (is_nil(v) or is_binary(v)) ->
          {:halt, {:error, "secret #{inspect(k)} must be a string or null"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # Merge-patch: string value sets, nil removes, everything else preserved.
  defp merge(existing, incoming) do
    Enum.reduce(incoming, existing, fn
      {k, nil}, acc -> Map.delete(acc, k)
      {k, v}, acc -> Map.put(acc, k, v)
    end)
  end

  # The decrypted secrets already on the record, read from the stored
  # `encrypted_secrets` column. On create there is no prior ciphertext, so this
  # is `%{}`.
  defp existing_secrets(%{data: %Workspace{} = data}), do: Workspace.secrets_map(data)
  defp existing_secrets(_changeset), do: %{}
end
