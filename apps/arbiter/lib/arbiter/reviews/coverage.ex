defmodule Arbiter.Reviews.Coverage do
  @moduledoc """
  P0 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.1/§3.3.

  `record/1` is the **only** writer of `Arbiter.Reviews.Coverage.Entry`
  rows. It is idempotent on `{mr_ref, head_sha, kind}` — a second identical
  call returns the existing row rather than inserting a duplicate, so every
  call site in §3.3 can call it unconditionally without first checking
  whether coverage already exists.

  This module is P0-only: nothing reads the table yet (that's `decide/3`
  from §3.2, and the call sites in §3.3), and no call site writes it yet.
  """

  require Ash.Query

  alias Arbiter.Reviews.Coverage.Entry

  @type attrs :: %{
          required(:task_id) => String.t(),
          required(:mr_ref) => String.t(),
          required(:head_sha) => String.t(),
          required(:base_ref) => String.t(),
          required(:net_diff_id) => String.t(),
          required(:kind) => :reviewed | :mechanical | :operator,
          required(:source) =>
            :review_gate | :review_patrol | :external_review | :watchdog | :cli,
          optional(:round) => integer() | nil,
          optional(:derived_from) => String.t() | nil,
          optional(:covered_at) => DateTime.t()
        }

  @doc """
  Record a coverage entry, or return the existing one if `{mr_ref, head_sha,
  kind}` was already recorded.

  A `:mechanical` row requires `derived_from`; any other kind must leave it
  nil. `head_sha` must be 40 hex characters. Both are rejected by the
  resource's create action and surfaced here as `{:error, _}`.
  """
  @spec record(attrs()) :: {:ok, Entry.t()} | {:error, term()}
  def record(attrs) do
    attrs = Map.new(attrs)

    case fetch_existing(attrs) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        Entry
        |> Ash.Changeset.for_create(:record, attrs)
        |> Ash.create()
        |> case do
          {:ok, entry} ->
            {:ok, entry}

          {:error, error} ->
            if unique_conflict?(error) do
              case fetch_existing(attrs) do
                {:ok, entry} -> {:ok, entry}
                :error -> {:error, error}
              end
            else
              {:error, error}
            end
        end
    end
  end

  defp fetch_existing(%{mr_ref: mr_ref, head_sha: head_sha, kind: kind}) do
    Entry
    |> Ash.Query.filter(mr_ref == ^mr_ref and head_sha == ^head_sha and kind == ^kind)
    |> Ash.read_one()
    |> case do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      _ -> :error
    end
  end

  defp fetch_existing(_attrs), do: :error

  defp unique_conflict?(%Ash.Error.Invalid{errors: errors}), do: Enum.any?(errors, &conflict?/1)
  defp unique_conflict?(_), do: false

  # The identity's `eager_check?: true` raises this shape on a duplicate
  # {mr_ref, head_sha, kind}; a DB-level unique-index hit under a genuine
  # race surfaces the same struct via the sqlite adapter's constraint match.
  defp conflict?(%Ash.Error.Changes.InvalidChanges{fields: fields}),
    do: :mr_ref in fields and :head_sha in fields and :kind in fields

  defp conflict?(_), do: false
end
