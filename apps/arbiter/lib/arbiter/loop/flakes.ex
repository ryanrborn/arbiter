defmodule Arbiter.Loop.Flakes do
  @moduledoc """
  `record/1` is the only writer of `Arbiter.Loop.FlakeEvent` rows (bd-6vullc).
  Its only call site is the `flake_record` MCP tool
  (`Arbiter.MCP.Tools.flake_record/2`), reached from a fix_pass that
  concludes a CI failure was a flake or infra issue — it re-ran the job with
  no code change and it went green (or is marking it broken repo-wide).

  `latest_fix_pass_run_id/1` resolves the `run_id` to attach: the fix_pass
  worker calling the tool has no run id of its own to hand over (its MCP
  scope only carries `task_id`), so this looks up the most recently started
  `fix_pass` `worker_runs` row for the task. Best-effort — a miss (the row
  raced, or was already superseded) leaves `run_id` nil rather than failing
  the whole record.
  """

  require Ash.Query

  alias Arbiter.Loop.FlakeEvent
  alias Arbiter.Workers.Run

  @type attrs :: %{
          required(:task_id) => String.t(),
          required(:repo) => String.t(),
          required(:ci_job) => String.t(),
          required(:signature) => String.t(),
          optional(:run_id) => String.t() | nil,
          optional(:test_file) => String.t() | nil,
          optional(:test_line) => integer() | nil,
          optional(:note) => String.t() | nil
        }

  @doc "Record a flake event. Every call inserts a new row — this table is append-only."
  @spec record(attrs()) :: {:ok, FlakeEvent.t()} | {:error, term()}
  def record(attrs) do
    attrs = Map.new(attrs)

    attrs =
      case Map.get(attrs, :run_id) do
        nil -> Map.put(attrs, :run_id, latest_fix_pass_run_id(Map.get(attrs, :task_id)))
        _ -> attrs
      end

    FlakeEvent
    |> Ash.Changeset.for_create(:record, attrs)
    |> Ash.create()
  end

  @doc "The most recently started `fix_pass` run for `task_id`, or nil."
  @spec latest_fix_pass_run_id(String.t() | nil) :: String.t() | nil
  def latest_fix_pass_run_id(nil), do: nil

  def latest_fix_pass_run_id(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id and worker_type == :fix_pass)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Run{id: id} | _] -> id
      [] -> nil
    end
  end
end
