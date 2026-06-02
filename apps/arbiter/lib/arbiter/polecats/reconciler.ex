defmodule Arbiter.Polecats.Reconciler do
  @moduledoc """
  Reconciles orphaned `:running` `Arbiter.Polecats.Run` rows on boot.

  A polecat GenServer is ephemeral: it writes a `:running` Run row on init and
  stamps the terminal status (`:completed` / `:failed`) when it stops. If the
  node dies between those two writes — a crash, a hard restart — the row is left
  `:running` forever. `arb prime` tracks live processes, so it correctly shows
  no active acolytes, but the durable history lies: it claims work is still in
  flight when the process that owned it is long gone.

  This module sweeps those orphans. A `:running` row whose `bead_id` has no live
  polecat registered under `Arbiter.Polecat.Registry` is marked `:failed` with a
  `failure_reason` of `"server restarted"`. Run on application start (see
  `Arbiter.Application`) after the Repo and the Polecat Registry are online.

  The sweep is best-effort: a DB hiccup logs a warning and returns `{:error, _}`
  rather than crashing the supervision tree at boot.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Polecat
  alias Arbiter.Polecats.Run

  # The failure_reason stamped onto reconciled orphans. Distinct, greppable,
  # and human-legible on the dashboard's "Completed Acolytes" view.
  @failure_reason "server restarted"

  @doc """
  Sweep `:running` Run rows with no live polecat and mark them `:failed`.

  Returns `{:ok, count}` where `count` is the number of rows reconciled, or
  `{:error, reason}` if the read failed (in which case nothing was written).
  """
  @spec reconcile_orphaned_runs() :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_orphaned_runs do
    orphans =
      Run
      |> Ash.Query.filter(status == :running)
      |> Ash.read!()
      |> Enum.reject(&live_polecat?/1)

    reconciled = Enum.count(orphans, &mark_interrupted/1)

    if reconciled > 0 do
      Logger.info("Polecats.Reconciler: marked #{reconciled} orphaned :running run(s) :failed")
    end

    {:ok, reconciled}
  rescue
    e ->
      Logger.warning("Polecats.Reconciler: sweep failed: #{Exception.message(e)}")
      {:error, e}
  end

  # A run is live iff a polecat GenServer is registered for its bead_id. After a
  # boot the registry is empty, so every :running row is an orphan; mid-life this
  # guards against racing a polecat that is legitimately still working.
  defp live_polecat?(%Run{bead_id: bead_id}), do: not is_nil(Polecat.whereis(bead_id))

  # Returns true when the row was successfully reconciled (so the caller can
  # count it), false on a per-row write failure that we've logged and skipped.
  defp mark_interrupted(%Run{} = run) do
    attrs = %{
      status: :failed,
      completed_at: DateTime.utc_now(),
      failure_reason: @failure_reason
    }

    case Ash.update(run, attrs, action: :update) do
      {:ok, _updated} ->
        true

      {:error, reason} ->
        Logger.warning(
          "Polecats.Reconciler: failed to reconcile run for bead=#{run.bead_id}: #{inspect(reason)}"
        )

        false
    end
  end
end
