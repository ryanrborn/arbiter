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

  ## Single-instance gate

  Liveness is keyed off the LOCAL process registry, which is empty on a fresh
  boot — so this sweep is only correct on the *one* canonical instance per DB.
  A second instance booting against the same DB (e.g. an acolyte running
  `mix phx.server` / `iex -S mix` / `mix run` while the real server is up) has
  an empty registry too, so it would mistake the primary instance's live runs
  for orphans and fail them. The boot path therefore gates the sweep on
  `Arbiter.SingleInstance.primary?/0` (a session advisory lock) and passes the
  verdict as the `:primary?` option; a non-primary boot skips the sweep
  entirely and returns `{:ok, :skipped}`. See bd-9rouwh / bd-6k8519.

  The sweep is best-effort: a DB hiccup logs a warning and returns `{:error, _}`
  rather than crashing the supervision tree at boot.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Beads.Issue
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat
  alias Arbiter.Polecats.Run

  # The failure_reason stamped onto reconciled orphans. Distinct, greppable,
  # and human-legible on the dashboard's "Completed Acolytes" view.
  @failure_reason "server restarted"

  @doc """
  Sweep `:running` Run rows with no live polecat and mark them `:failed`.

  Returns `{:ok, count}` where `count` is the number of rows reconciled, or
  `{:error, reason}` if the read failed (in which case nothing was written).

  ## Options

    * `:primary?` — whether this instance is the canonical single instance and
      may sweep. Defaults to `true` (the mechanism is permissive on its own;
      the boot path supplies the real verdict from `Arbiter.SingleInstance`).
      When `false`, the sweep is skipped and `{:ok, :skipped}` is returned
      without touching any row — this is what keeps a transient/duplicate boot
      from failing the primary instance's live runs.
  """
  @spec reconcile_orphaned_runs(keyword()) ::
          {:ok, non_neg_integer() | :skipped} | {:error, term()}
  def reconcile_orphaned_runs(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile()
    else
      Logger.info(
        "Polecats.Reconciler: not the primary instance; skipping orphan sweep " <>
          "(advisory lock held elsewhere)"
      )

      {:ok, :skipped}
    end
  end

  defp do_reconcile do
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

  @doc """
  Find `:in_progress` Issues with a `pr_ref` but no live polecat, and escalate
  each to Admiral as an addressed `:escalation` mailbox message.

  This covers the specific failure mode where the server is killed between the
  implementer finishing (`arb done` → PR opened, `pr_ref` written to the Issue)
  and the Tribunal/Warden hand-off being established. After a reboot the polecat
  process no longer exists, so the Warden that would merge the PR was never
  spawned. The Issue is stuck `:in_progress` with an open PR and no driver.

  Returns `{:ok, count}` or `{:error, reason}`.

  ## Options

    * `:primary?` — same single-instance gate as `reconcile_orphaned_runs/1`.
      When `false`, skips and returns `{:ok, :skipped}`.
  """
  @spec reconcile_open_pr_beads(keyword()) ::
          {:ok, non_neg_integer() | :skipped} | {:error, term()}
  def reconcile_open_pr_beads(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile_open_pr_beads()
    else
      {:ok, :skipped}
    end
  end

  defp do_reconcile_open_pr_beads do
    stuck =
      Issue
      |> Ash.Query.filter(status == :in_progress and not is_nil(pr_ref))
      |> Ash.read!()
      |> Enum.reject(&live_polecat_for_issue?/1)

    escalated = Enum.count(stuck, &escalate_stuck_issue/1)

    if escalated > 0 do
      Logger.warning(
        "Polecats.Reconciler: found #{escalated} in_progress bead(s) with open PR but no live polecat — escalated to Admiral"
      )
    end

    {:ok, escalated}
  rescue
    e ->
      Logger.warning("Polecats.Reconciler: open-PR bead sweep failed: #{Exception.message(e)}")

      {:error, e}
  end

  defp live_polecat_for_issue?(%Issue{id: bead_id}), do: not is_nil(Polecat.whereis(bead_id))

  defp escalate_stuck_issue(%Issue{id: bead_id, pr_ref: pr_ref, workspace_id: workspace_id}) do
    subject = "#{bead_id} stuck — PR ##{pr_ref} open but no live polecat"

    body =
      "Bead #{bead_id} has an open PR (#{pr_ref}) but no live polecat to drive the merge.\n" <>
        "The server was likely restarted between `arb done` and the Warden being established.\n" <>
        "Action: verify the PR is ready to merge, then run `arb sling #{bead_id}` to re-drive " <>
        "or manually merge and close the bead."

    Message.send_mail(%{
      kind: :escalation,
      to_ref: "admiral",
      from_ref: "system",
      workspace_id: workspace_id,
      directive_ref: bead_id,
      subject: subject,
      body: body
    })

    true
  rescue
    e ->
      Logger.warning(
        "Polecats.Reconciler: failed to escalate stuck bead #{bead_id}: #{Exception.message(e)}"
      )

      false
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
