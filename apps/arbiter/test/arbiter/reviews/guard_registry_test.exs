defmodule Arbiter.Reviews.GuardRegistryTest do
  @moduledoc """
  The two tests that give `Arbiter.Reviews.GuardRegistry` teeth (design #1635
  §5.4, P8).

  1. **Completeness** — every refusal path the AST scan finds in the six
     control-plane modules is accounted for: it is either a registry row's site
     or an entry in `@non_guard_sites` with a reason. Adding an escalation or a
     `Worker.fail/2` to any of those modules fails this file until it is
     declared. Both lists are also asserted to be free of stale entries, so a
     deleted function cannot leave a row or an exemption behind.

  2. **Policy conformance** — every row has a class, a finite bound and an
     episode key; no bound is infinite; no class-A or class-F row reaches
     `Worker.fail/2`; no row converts a guard misfire into `Run.status =
     :failed`. The rows that break those rules today are enumerated in
     `GuardRegistry.known_violations/0`, each naming the §7 phase that removes
     it, and that list is frozen here so it can only shrink.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Reviews.GuardRegistry
  alias Arbiter.Test.GuardRefusalScan

  @repo_root Path.expand("../../../../..", __DIR__)
  @doc_path Path.join(@repo_root, "docs/review-coverage-and-guard-policy.md")

  # Refusal sites the scan finds that are NOT review/merge guards. Each needs a
  # reason, and each must still exist in its module — an exemption that outlives
  # its function is how a freeze rots. A new entry here is a deliberate,
  # reviewable act; that is the point.
  @non_guard_sites [
    # --- review_gate.ex ---
    {Arbiter.Worker.ReviewGate, :persist_message, 4,
     "thread persistence: mails the review thread, not an escalation"},
    {Arbiter.Worker.ReviewGate, :durable_lines, 1,
     "reads the durable transcript; {:error, :no_run_id} is a lookup miss"},
    {Arbiter.Worker.ReviewGate, :prepare_branch_for_review, 1,
     "checkout/rebase failure before the review starts; surfaced through G1's " <>
       "escalate_pre_review path. §2 does not inventory it as a guard — P10's audit owns it"},
    {Arbiter.Worker.ReviewGate, :start_worker_process, 3,
     "agent spawn failure: infrastructure, not a refusal of the work"},
    {Arbiter.Worker.ReviewGate, :start_worker_session, 5,
     "agent session failure: infrastructure, not a refusal of the work"},

    # --- watchdog.ex ---
    {Arbiter.Worker.Watchdog, :maybe_notify_awaiting_manual_merge, 2,
     "status page (approved, awaiting a human merge); blocks nothing"},
    {Arbiter.Worker.Watchdog, :maybe_escalate_pipeline, 2,
     "CI pipeline-failure page; reports the pipeline's verdict, refuses nothing"},
    {Arbiter.Worker.Watchdog, :retry_auto_resolve, 1,
     "operator API entry point; {:error, :not_found | :busy} is argument validation"},
    {Arbiter.Worker.Watchdog, :rerun_ci, 2, "operator API entry point; argument validation"},
    {Arbiter.Worker.Watchdog, :mark_ci_external, 2,
     "operator API entry point; argument validation"},
    {Arbiter.Worker.Watchdog, :handle_call, 3,
     "GenServer call plumbing for the operator API above"},

    # --- merge_queue.ex ---
    {Arbiter.Workflows.MergeQueue, :safe_escalate, 5,
     "the queue's conflict-resolution page; the Watchdog's equivalent is W18"},
    {Arbiter.Workflows.MergeQueue, :push_worktree_branch, 3,
     "git push failure: infrastructure, not a review/merge refusal"},
    {Arbiter.Workflows.MergeQueue, :reconcile_worktree_before_push, 3,
     "divergence detection before push; the merge guard runs later"},
    {Arbiter.Workflows.MergeQueue, :maybe_link_mr_to_tracker, 4,
     "{:error, :not_supported} from a tracker adapter that cannot link"},

    # --- worker.ex ---
    {Arbiter.Worker, :fail, 2,
     "the public sink every failure arrives at, not a guard of its own"},
    {Arbiter.Worker, :fail_stopped, 2, "records an externally stopped worker"},
    {Arbiter.Worker, :fail_missing_worktree, 1,
     "the worktree vanished under a running worker: infrastructure"},
    {Arbiter.Worker, :broadcast_done, 1, "completion notification"},
    {Arbiter.Worker, :handle_call, 3, "awaiting-review status notification"},
    {Arbiter.Worker, :escalate_output_log_failure, 2,
     "the output log could not be opened: infrastructure"},
    {Arbiter.Worker, :park_notes_gate, 2,
     "the PR-notes gate (task notes missing), a separate gate from review coverage"},
    {Arbiter.Worker, :escalate_notes_gate, 2, "see park_notes_gate/2"},
    {Arbiter.Worker, :park_merge_failure, 3,
     "the worker's own merge attempt failed; the merge guard is W1–W7 / M1–M3"},
    {Arbiter.Worker, :escalate_merge_conflict, 3, "see park_merge_failure/3"},
    {Arbiter.Worker, :escalate_merge_failure, 3, "see park_merge_failure/3"},
    {Arbiter.Worker, :escalate_watchdog_failure, 1,
     "the Watchdog could not be spawned or was lost: infrastructure"},
    {Arbiter.Worker, :notify_review_gate_reconciled, 2,
     "reconciliation notice; the opposite of a refusal"},

    # --- review_patrol.ex ---
    {Arbiter.Workflows.ReviewPatrol, :escalate_rate_limit, 3,
     "forge rate-limit circuit breaker, not a review/merge guard"},
    {Arbiter.Workflows.ReviewPatrol, :escalate_circuit_breaker, 3,
     "the generic auto-filing circuit breaker (#1638), which guards the guards"},
    {Arbiter.Workflows.ReviewPatrol, :escalate_reply, 4,
     "relays an author's reply to the coordinator"},
    {Arbiter.Workflows.ReviewPatrol, :report_to_coordinator, 4,
     "posts a completed review's result to the coordinator; reports, refuses nothing"},
    {Arbiter.Workflows.ReviewPatrol, :flag_new_commits, 3,
     "tells the coordinator a watched PR grew new commits; informational"},
    {Arbiter.Workflows.ReviewPatrol, :fetch_new_diff, 3,
     "{:error, :get_diff_unsupported} from a forge adapter"},

    # --- pr_patrol.ex ---
    {Arbiter.Workflows.PRPatrol, :init, 1,
     "injects Message.send_mail/1 as the default escalation sink"},
    {Arbiter.Workflows.PRPatrol, :dispatch_follow_up, 3,
     "{:error, :quota_held} — the quota system's hold, bounded by Arbiter.Quota"}
  ]

  @bound_units [
    :attempts,
    :deferrals,
    :escalations,
    :evaluations,
    :polls,
    :retries,
    :reviews,
    :rounds
  ]

  # §7's phase ids. A violation must name one of these as the phase that removes
  # it, so "we'll fix it later" cannot be written down without a schedule.
  @phases ~w(p0 p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12)a

  # The frozen violation set. Entries may be REMOVED as phases land; adding one
  # fails this test. AC4.
  @frozen_violations [
    {:queue_stale_sha_retry, :unbounded_retry},
    {:merge_expected_sha, :unbounded_retry},
    {:ci_settle_gate, :unbounded_retry},
    {:unreviewed_head_reroute, :reaches_worker_fail},
    {:unreviewed_head_reroute, :fails_run},
    {:empty_diff_range, :fails_run},
    {:reviewing_timeout, :fails_run},
    {:verdict_reprompt_budget, :fails_run},
    {:empty_findings, :fails_run},
    {:partial_verification, :fails_run},
    {:unaddressed_findings, :fails_run},
    {:unmet_criteria, :fails_run},
    {:missing_criteria, :fails_run},
    {:round_budget, :fails_run},
    {:commit_gate_head_unchanged, :fails_run},
    {:commit_gate_escalation, :fails_run},
    {:rejection_parking, :fails_run},
    {:poll_ceiling, :fails_run}
  ]

  setup_all do
    sources =
      Map.new(GuardRegistry.control_plane(), fn entry ->
        {entry.module, File.read!(Path.join(@repo_root, entry.path))}
      end)

    {:ok, sources: sources}
  end

  describe "inventory coverage (AC1)" do
    test "every guard in the design doc's §2 inventory has exactly one row" do
      doc_ids = inventory_ids()

      assert length(doc_ids) == 60,
             "expected §2's 60 inventory rows, parsed #{length(doc_ids)} — has the doc's " <>
               "table shape changed?"

      missing = doc_ids -- GuardRegistry.doc_refs()

      assert missing == [],
             "§2 inventory ids with no GuardRegistry row: #{Enum.join(missing, ", ")}"

      extra = GuardRegistry.doc_refs() -- doc_ids

      assert extra == [],
             "GuardRegistry rows citing a §2 id that no longer exists: #{Enum.join(extra, ", ")}"
    end

    test "row ids and doc refs are unique" do
      ids = GuardRegistry.ids()
      assert ids == Enum.uniq(ids), "duplicate registry ids: #{inspect(ids -- Enum.uniq(ids))}"

      refs = GuardRegistry.doc_refs()

      assert refs == Enum.uniq(refs),
             "duplicate §2 refs: #{inspect(refs -- Enum.uniq(refs))}"
    end

    test "fetch!/1 raises on an unknown id rather than defaulting" do
      assert %{doc_ref: "W7"} = GuardRegistry.fetch!(:merge_expected_sha)

      assert_raise ArgumentError, fn -> GuardRegistry.fetch!(:no_such_guard) end
    end

    test "every declared site still exists in its module", %{sources: sources} do
      defined =
        Map.new(sources, fn {module, source} ->
          {module, MapSet.new(GuardRefusalScan.definitions(source))}
        end)

      stale =
        for row <- GuardRegistry.guards(),
            {module, fun, arity} <- row.sites,
            not MapSet.member?(Map.fetch!(defined, module), {fun, arity}),
            do: "#{row.doc_ref} (#{row.id}) -> #{inspect(module)}.#{fun}/#{arity}"

      assert stale == [],
             "registry rows pointing at functions that no longer exist:\n  " <>
               Enum.join(stale, "\n  ")
    end

    test "every declared anchor still appears in its module", %{sources: sources} do
      stale =
        for row <- GuardRegistry.guards(),
            {module, _, _} = hd(row.sites),
            anchor <- row.anchors,
            not String.contains?(Map.fetch!(sources, module), anchor),
            do: "#{row.doc_ref} (#{row.id}) -> #{inspect(module)} no longer contains #{anchor}"

      assert stale == [],
             "registry anchors that have drifted:\n  " <> Enum.join(stale, "\n  ")
    end

    test "every exempted non-guard site still exists", %{sources: sources} do
      defined =
        Map.new(sources, fn {module, source} ->
          {module, MapSet.new(GuardRefusalScan.definitions(source))}
        end)

      stale =
        for {module, fun, arity, _reason} <- @non_guard_sites,
            not MapSet.member?(Map.fetch!(defined, module), {fun, arity}),
            do: "#{inspect(module)}.#{fun}/#{arity}"

      assert stale == [],
             "@non_guard_sites entries whose function is gone — delete them:\n  " <>
               Enum.join(stale, "\n  ")
    end

    test "every exempted non-guard site carries a reason" do
      blank =
        for {module, fun, arity, reason} <- @non_guard_sites,
            not (is_binary(reason) and String.length(reason) > 20),
            do: "#{inspect(module)}.#{fun}/#{arity}"

      assert blank == [], "exemptions without a real reason: " <> Enum.join(blank, ", ")
    end
  end

  describe "refusal-path completeness (AC2)" do
    test "every refusal path in the control plane is declared", %{sources: sources} do
      declared = declared_sites()
      exempt = MapSet.new(@non_guard_sites, fn {m, f, a, _} -> {m, f, a} end)

      unaccounted =
        for entry <- GuardRegistry.control_plane(),
            {{fun, arity}, signals} <-
              GuardRefusalScan.scan(Map.fetch!(sources, entry.module), entry.signals),
            not MapSet.member?(declared, {entry.module, fun, arity}),
            not MapSet.member?(exempt, {entry.module, fun, arity}),
            do: "#{inspect(entry.module)}.#{fun}/#{arity} (#{Enum.join(signals, ", ")})"

      assert unaccounted == [],
             """
             Unregistered refusal path(s) in the review/merge control plane.

             Invariant I4 of docs/review-coverage-and-guard-policy.md §5.1: a guard
             that is not in the registry does not exist. Either add a row to
             Arbiter.Reviews.GuardRegistry (class, finite bound, episode key, sites)
             or, if this is not a review/merge guard, add it to @non_guard_sites in
             this file with a reason.

               #{Enum.join(unaccounted, "\n  ")}
             """
    end

    test "the scan detects an unregistered refusal path (red capability)" do
      source = """
      defmodule Arbiter.Worker.Watchdog do
        defp guarded_merge_decision(state), do: {:error, {:stale_reviewed_sha, state}}

        defp escalate_brand_new_guard(state) do
          Arbiter.Messages.CoordinatorNotifier.merge_blocked(state, state.mr_ref, :nope)
          Worker.fail(state.worker_pid, {:brand_new_refusal, state})
        end
      end
      """

      sites = source |> GuardRefusalScan.scan([:name, :prim, :tagged]) |> Enum.map(&elem(&1, 0))

      assert {:escalate_brand_new_guard, 1} in sites,
             "the scan must flag a new escalating/failing function, or the freeze is toothless"

      declared = declared_sites()
      exempt = MapSet.new(@non_guard_sites, fn {m, f, a, _} -> {m, f, a} end)

      refute MapSet.member?(declared, {Arbiter.Worker.Watchdog, :escalate_brand_new_guard, 1})
      refute MapSet.member?(exempt, {Arbiter.Worker.Watchdog, :escalate_brand_new_guard, 1})
    end

    test "the scan picks up each of its three signals independently" do
      source = """
      defmodule Fixture do
        defp escalate_by_name(x), do: x
        defp refuses_by_primitive(x), do: Arbiter.Worker.fail(x, :nope)
        defp refuses_by_tuple(x), do: {:error, {:stale_reviewed_sha, x}}
        defp safe_wrapper(x), do: {:error, {:exception, x}}
        defp not_a_refusal(x), do: x + 1
      end
      """

      by_name = source |> GuardRefusalScan.scan([:name]) |> Enum.map(&elem(&1, 0))
      by_prim = source |> GuardRefusalScan.scan([:prim]) |> Enum.map(&elem(&1, 0))
      by_tuple = source |> GuardRefusalScan.scan([:tagged]) |> Enum.map(&elem(&1, 0))

      assert {:escalate_by_name, 1} in by_name
      assert {:refuses_by_primitive, 1} in by_prim
      assert {:refuses_by_tuple, 1} in by_tuple

      refute {:not_a_refusal, 1} in (by_name ++ by_prim ++ by_tuple)

      refute {:safe_wrapper, 1} in by_tuple,
             "exception-capture wrappers are error adapters, not refusals"

      refute {:refuses_by_tuple, 1} in by_name,
             "signals must be independently selectable, or the per-module config is a lie"
    end

    test "the sites the registry declares are really the ones the scan sees", %{sources: sources} do
      # Not every row's site is scan-visible (a pure predicate such as
      # `debounced?/2` refuses by returning false), but the escalation and
      # failure leaves must be — otherwise the scan is not actually watching the
      # code the registry claims to cover.
      detected =
        for entry <- GuardRegistry.control_plane(),
            {{fun, arity}, _signals} <-
              GuardRefusalScan.scan(Map.fetch!(sources, entry.module), entry.signals),
            into: MapSet.new(),
            do: {entry.module, fun, arity}

      covered = MapSet.intersection(detected, declared_sites())

      assert MapSet.size(covered) >= 30,
             "the scan only recognises #{MapSet.size(covered)} of the registry's declared " <>
               "sites; expected at least 30"
    end
  end

  describe "policy conformance (AC3)" do
    test "every row has a class, and an inferred class explains itself" do
      bad =
        for row <- GuardRegistry.guards(),
            reason = class_problem(row),
            do: "#{row.doc_ref} (#{row.id}): #{reason}"

      assert bad == [], Enum.join(bad, "\n")
    end

    test "every row has a finite bound" do
      infinite =
        for row <- GuardRegistry.guards(),
            not GuardRegistry.finite_bound?(row.bound),
            not GuardRegistry.violation?(row.id, :unbounded_retry),
            do: "#{row.doc_ref} (#{row.id}): bound #{inspect(row.bound)}"

      assert infinite == [],
             "rows with no finite bound and no recorded violation (I1):\n  " <>
               Enum.join(infinite, "\n  ")
    end

    test "no row declares bound: :infinity in any form" do
      offenders =
        for row <- GuardRegistry.guards(),
            :infinity in Tuple.to_list(row.bound),
            do: "#{row.doc_ref} (#{row.id})"

      assert offenders == [],
             ":infinity is never a bound — an unbounded guard is recorded as " <>
               "{unit, :unbounded} plus a known_violations entry: " <> Enum.join(offenders, ", ")
    end

    test "every bound uses a declared unit, and config bounds are anchored" do
      bad =
        for row <- GuardRegistry.guards(),
            reason = bound_problem(row),
            do: "#{row.doc_ref} (#{row.id}): #{reason}"

      assert bad == [], Enum.join(bad, "\n")
    end

    test "every row has an episode key (I3)" do
      bad =
        for row <- GuardRegistry.guards(),
            reason = episode_problem(row),
            do: "#{row.doc_ref} (#{row.id}): #{reason}"

      assert bad == [], Enum.join(bad, "\n")
    end

    test "every row declares a terminal state from the closed set" do
      bad =
        for row <- GuardRegistry.guards(),
            row.terminal not in GuardRegistry.terminals(),
            do: "#{row.doc_ref} (#{row.id}): #{inspect(row.terminal)}"

      assert bad == [], "unknown terminal states: " <> Enum.join(bad, ", ")
    end

    test "every row names its sites, anchors and a summary" do
      bad =
        for row <- GuardRegistry.guards(),
            reason = shape_problem(row),
            do: "#{row.doc_ref} (#{row.id}): #{reason}"

      assert bad == [], Enum.join(bad, "\n")
    end

    test "no class-A or class-F row reaches Worker.fail/2", %{sources: sources} do
      offenders =
        for row <- GuardRegistry.guards(),
            row.class in [:a, :f],
            reaches_worker_fail?(row, sources),
            not GuardRegistry.violation?(row.id, :reaches_worker_fail),
            do: "#{row.doc_ref} (#{row.id}, class #{row.class})"

      assert offenders == [],
             """
             §5.3: class A (merge authorisation) and class F (filing & escalation)
             fail CLOSED — they park and escalate once. Neither may fail the run.
             These rows reach Worker.fail/2 and are not on known_violations:

               #{Enum.join(offenders, "\n  ")}
             """
    end

    test "the class-A/F reachability check actually detects a fail path", %{sources: sources} do
      # W6 is the one class-A row that does call Worker.fail/2 today. If this
      # stops being true the check above is passing for the wrong reason.
      assert reaches_worker_fail?(GuardRegistry.fetch!(:unreviewed_head_reroute), sources),
             "W6 no longer reaches Worker.fail/2 — remove its known_violations entry"

      refute reaches_worker_fail?(GuardRegistry.fetch!(:merge_expected_sha), sources),
             "W7 does not fail the run; the reachability walk is over-reporting"
    end

    test "no row converts a guard misfire into a failed run (I2)" do
      offenders =
        for row <- GuardRegistry.guards(),
            row.terminal in [:failed_run, :retries_forever],
            not GuardRegistry.violation?(row.id, :fails_run),
            not GuardRegistry.violation?(row.id, :unbounded_retry),
            do: "#{row.doc_ref} (#{row.id}): #{row.terminal}"

      assert offenders == [],
             "rows whose terminal state breaks I1/I2 with no recorded violation:\n  " <>
               Enum.join(offenders, "\n  ")
    end

    test "failing the run by design requires a written justification" do
      bad =
        for row <- GuardRegistry.guards(),
            row.terminal == :failed_run_by_design,
            not is_binary(row[:policy_note]),
            do: "#{row.doc_ref} (#{row.id})"

      assert bad == [],
             ":failed_run_by_design needs a :policy_note saying why the failure is " <>
               "honest rather than a misfire: " <> Enum.join(bad, ", ")
    end
  end

  describe "known violations (AC4)" do
    test "the violation list may only shrink" do
      current = MapSet.new(GuardRegistry.known_violations(), &{&1.id, &1.violation})
      frozen = MapSet.new(@frozen_violations)

      added = MapSet.difference(current, frozen) |> MapSet.to_list()

      assert added == [],
             """
             known_violations/0 gained an entry: #{inspect(added)}

             The list is frozen (AC4): it may shrink as the §7 phases land, never
             grow. A new guard must conform to §5's policy — finite bound, park and
             escalate once, never fail the run — instead of being exempted.
             """
    end

    test "every violation names an existing row, a violation kind and a removing phase" do
      ids = GuardRegistry.ids()

      bad =
        for violation <- GuardRegistry.known_violations(),
            reason = violation_problem(violation, ids),
            do: "#{inspect(violation[:id])}: #{reason}"

      assert bad == [], Enum.join(bad, "\n")
    end

    test "the removing phase is one the design doc actually schedules" do
      doc = File.read!(@doc_path)

      missing =
        for violation <- GuardRegistry.known_violations(),
            phase = violation.removed_by |> Atom.to_string() |> String.upcase(),
            not String.contains?(doc, "**#{phase}**"),
            do: "#{violation.id} -> #{phase}"

      assert missing == [],
             "violations pointing at a phase §7 does not list:\n  " <> Enum.join(missing, "\n  ")
    end

    test "every unbounded row and every failed-run row is on the list" do
      unbounded =
        for row <- GuardRegistry.guards(),
            not GuardRegistry.finite_bound?(row.bound),
            do: row.id

      assert Enum.sort(unbounded) ==
               Enum.sort([:merge_expected_sha, :queue_stale_sha_retry, :ci_settle_gate]),
             "the set of unbounded guards changed: #{inspect(unbounded)}. §2.6 names M3, W7 " <>
               "and R2 as the only ones; a new one is an I1 regression."

      failing =
        for row <- GuardRegistry.guards(), row.terminal == :failed_run, do: row.doc_ref

      # §2.6's thirteen, plus C2 — the conversion point all thirteen route
      # through. §2.6 counts C2 as the mechanism ("this is *where*
      # `:review_gate_inconclusive` becomes a failed run") rather than as a
      # fourteenth guard; the registry needs a row for it either way, because P9
      # changes that row's behaviour.
      assert Enum.sort(failing) ==
               Enum.sort(~w(G2 G3 G6 G8 G9 G10 G11 G12 G14 G15 G16 W6 W12 C2)),
             "the set of guards that convert a guard decision into a failed run changed: " <>
               inspect(Enum.sort(failing))
    end
  end

  describe "class assignment against §5.3" do
    test "every class in §5.3's table is represented" do
      for class <- GuardRegistry.classes() do
        assert GuardRegistry.by_class(class) != [],
               "no row is in class #{class}, but §5.3 defines it"
      end
    end

    test "the classes §5.3 assigns explicitly are the ones recorded" do
      # §5.3's table, transcribed. Rows outside it are :inferred and explain
      # themselves (asserted above).
      doc_classes = %{
        a: ~w(W1 W2 W3 W4 W5 W6 W7 M1 M2 M3),
        b: ~w(G1 G2),
        c: ~w(G5 G6 G7 G8 G9 G10 G11 G12 G13),
        d: ~w(G14 G15 G16 C1 C3),
        e: ~w(W11 W12 W13 W14 W15 W16 W17 W18 W19 M7),
        f: ~w(R2 R3 R4 R5 R6 P1 P2 P3 P4 P5 P6 P7)
      }

      for {class, refs} <- doc_classes, ref <- refs do
        row = GuardRegistry.by_doc_ref(ref)
        assert row, "§5.3 assigns #{ref} to class #{class} but there is no row for it"

        assert row.class == class,
               "#{ref} is class #{row.class} in the registry, class #{class} in §5.3"

        assert row.class_source == :doc,
               "#{ref} is classed by §5.3, so its :class_source must be :doc"
      end

      doc_refs = doc_classes |> Map.values() |> List.flatten()

      for row <- GuardRegistry.guards(), row.doc_ref not in doc_refs do
        assert row.class_source == :inferred,
               "#{row.doc_ref} is not in §5.3's table, so its class is inferred"
      end
    end
  end

  ## Helpers

  defp inventory_ids do
    doc = File.read!(@doc_path)

    [_, section] = String.split(doc, "## 2. Guard inventory", parts: 2)
    [section, _] = String.split(section, "## 3. The review-coverage model", parts: 2)

    ~r/^\| ([GWMCRP]\d+) \|/m
    |> Regex.scan(section)
    |> Enum.map(fn [_, id] -> id end)
  end

  defp declared_sites do
    for row <- GuardRegistry.guards(), site <- row.sites, into: MapSet.new(), do: site
  end

  defp class_problem(row) do
    cond do
      row.class not in GuardRegistry.classes() ->
        "class #{inspect(row.class)} is not one of #{inspect(GuardRegistry.classes())}"

      row.class_source not in [:doc, :inferred] ->
        "class_source #{inspect(row.class_source)} must be :doc or :inferred"

      row.class_source == :inferred and not is_binary(row[:class_note]) ->
        "an inferred class needs a :class_note explaining the reasoning"

      true ->
        nil
    end
  end

  defp bound_problem(row) do
    case row.bound do
      {unit, _} when unit not in @bound_units ->
        "bound unit #{inspect(unit)} is not in #{inspect(GuardRegistry.bound_units())}"

      {_unit, {:config, name}} ->
        anchored? = Enum.any?(row.anchors, &String.contains?(&1, Atom.to_string(name)))

        unless anchored? do
          "config bound #{inspect(name)} is not named in :anchors, so nothing pins it to the source"
        end

      {_unit, n} when is_integer(n) and n > 0 ->
        nil

      {_unit, :unbounded} ->
        nil

      other ->
        "bound #{inspect(other)} has no recognised shape"
    end
  end

  defp episode_problem(row) do
    keys = Tuple.to_list(row.episode)

    cond do
      keys == [] -> "episode key is empty; I3 needs a reset condition"
      not Enum.all?(keys, &is_atom/1) -> "episode keys must be atoms, got #{inspect(row.episode)}"
      true -> nil
    end
  end

  defp shape_problem(row) do
    cond do
      row.sites == [] ->
        "no :sites — a row with no code is not a guard"

      not Enum.all?(
        row.sites,
        &match?({mod, fun, arity} when is_atom(mod) and is_atom(fun) and is_integer(arity), &1)
      ) ->
        "sites must be {module, function, arity}"

      row.anchors == [] ->
        "no :anchors — nothing keeps the row pinned to the source"

      not (is_binary(row.summary) and String.length(row.summary) > 20) ->
        "no usable :summary"

      true ->
        nil
    end
  end

  defp violation_problem(violation, ids) do
    cond do
      violation.id not in ids ->
        "no registry row with this id"

      violation.violation not in [:unbounded_retry, :fails_run, :reaches_worker_fail] ->
        "unknown violation kind #{inspect(violation.violation)}"

      violation.removed_by not in @phases ->
        "removed_by #{inspect(violation.removed_by)} is not a §7 phase"

      not (is_binary(violation.note) and String.length(violation.note) > 30) ->
        "no usable :note saying what the current behaviour is"

      true ->
        nil
    end
  end

  # Walk the module's local call graph from the row's own sites, pruning any
  # function that is another row's site: each row owns the code between its own
  # sites and the next row's. Reports whether that region calls Worker.fail/2
  # (or worker.ex's local fail_now/2).
  defp reaches_worker_fail?(row, sources) do
    {module, _, _} = hd(row.sites)
    graph = GuardRefusalScan.call_graph(Map.fetch!(sources, module))

    own = MapSet.new(row.sites, fn {_m, f, a} -> {f, a} end)

    foreign =
      for other <- GuardRegistry.guards(),
          other.id != row.id,
          {^module, fun, _arity} <- other.sites,
          into: MapSet.new(),
          do: fun

    walk(MapSet.to_list(own), MapSet.new(), graph, foreign)
  end

  defp walk([], _seen, _graph, _foreign), do: false

  defp walk([site | rest], seen, graph, foreign) do
    cond do
      MapSet.member?(seen, site) ->
        walk(rest, seen, graph, foreign)

      true ->
        seen = MapSet.put(seen, site)
        entry = Map.get(graph, site, %{calls: [], fails_run?: false})

        if entry.fails_run? do
          true
        else
          next =
            for name <- entry.calls,
                name not in [elem(site, 0)],
                not MapSet.member?(foreign, name),
                {^name, arity} <- Map.keys(graph),
                do: {name, arity}

          walk(rest ++ next, seen, graph, foreign)
        end
    end
  end
end
