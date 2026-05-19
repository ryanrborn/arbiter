defmodule GtElixir.PolecatTest do
  # async: false because the polecat registry + dynamic supervisor are
  # singletons shared across tests; we use unique bead_ids per test to keep
  # cases independent, but we still don't want parallel runs racing on the
  # registry itself.
  use ExUnit.Case, async: false

  alias GtElixir.Polecat

  # Generate a unique bead_id per test so tests don't collide on the registry.
  defp new_bead_id, do: "gte-test-#{System.unique_integer([:positive])}"

  defp start_polecat(opts \\ []) do
    bead_id = Keyword.get(opts, :bead_id, new_bead_id())
    rig = Keyword.get(opts, :rig, "gt-elixir")

    opts =
      opts
      |> Keyword.put_new(:bead_id, bead_id)
      |> Keyword.put_new(:rig, rig)

    {:ok, pid} = Polecat.start(opts)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {pid, bead_id}
  end

  describe "start/1 + lifecycle" do
    test "starts, registers in the registry, exposes defaults via state/1" do
      {pid, bead_id} = start_polecat(workspace_id: "ws-1")

      assert Polecat.whereis(bead_id) == pid

      snap = Polecat.state(pid)
      assert snap.bead_id == bead_id
      assert snap.rig == "gt-elixir"
      assert snap.workspace_id == "ws-1"
      assert snap.current_step == :idle
      assert snap.status == :idle
      assert %DateTime{} = snap.started_at
      assert snap.step_started_at == nil
      assert snap.meta == %{}
    end

    test "state/1 accepts bead_id strings" do
      {_pid, bead_id} = start_polecat()
      assert %{bead_id: ^bead_id} = Polecat.state(bead_id)
    end

    test "state/1 on unknown bead_id returns nil (doesn't crash)" do
      assert Polecat.state("gte-nope-#{System.unique_integer([:positive])}") == nil
    end

    test "start_link/1 without :bead_id returns {:error, :missing_bead_id}" do
      assert Polecat.start_link(rig: "gt-elixir") == {:error, :missing_bead_id}
    end

    test "start_link/1 without :rig returns {:error, :missing_rig}" do
      assert Polecat.start_link(bead_id: new_bead_id()) == {:error, :missing_rig}
    end

    test "starting a second polecat for the same bead_id returns :already_started" do
      {pid, bead_id} = start_polecat()

      assert {:error, {:already_started, ^pid}} =
               Polecat.start(bead_id: bead_id, rig: "gt-elixir")
    end
  end

  describe "advance/2" do
    test "from :idle → step transitions status to :running and sets step_started_at" do
      {pid, _} = start_polecat()
      assert :ok = Polecat.advance(pid, :load)

      snap = Polecat.state(pid)
      assert snap.current_step == :load
      assert snap.status == :running
      assert %DateTime{} = snap.step_started_at
    end

    test "sequential advances update step but keep status=:running" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :load)
      first = Polecat.state(pid).step_started_at
      # ensure a measurable tick between advances
      Process.sleep(5)
      :ok = Polecat.advance(pid, :design)

      snap = Polecat.state(pid)
      assert snap.current_step == :design
      assert snap.status == :running
      assert DateTime.compare(snap.step_started_at, first) == :gt
    end

    test "advance/2 by bead_id works too" do
      {_pid, bead_id} = start_polecat()
      assert :ok = Polecat.advance(bead_id, :load)
      assert Polecat.state(bead_id).current_step == :load
    end

    test "advance/2 on unknown bead_id returns {:error, :not_found}" do
      assert {:error, :not_found} = Polecat.advance("nope-#{System.unique_integer()}", :load)
    end
  end

  describe "await / resume" do
    test "await/2 from :running transitions to :awaiting and stores reason" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :verify)
      :ok = Polecat.await(pid, :pr_review)

      snap = Polecat.state(pid)
      assert snap.status == :awaiting
      assert snap.meta[:await_reason] == :pr_review
    end

    test "resume/1 from :awaiting transitions back to :running" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :verify)
      :ok = Polecat.await(pid, :pr_review)
      :ok = Polecat.resume(pid)

      snap = Polecat.state(pid)
      assert snap.status == :running
      refute Map.has_key?(snap.meta, :await_reason)
    end

    test "await/2 from :idle is rejected" do
      {pid, _} = start_polecat()
      assert {:error, {:invalid_transition, :idle, :awaiting}} = Polecat.await(pid)
    end

    test "resume/1 from :running is rejected" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :load)
      assert {:error, {:invalid_transition, :running, :running}} = Polecat.resume(pid)
    end
  end

  describe "complete / fail" do
    test "complete/2 from :running transitions to :completed" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :submit)
      :ok = Polecat.complete(pid, %{pr: "https://example.com/pr/1"})

      snap = Polecat.state(pid)
      assert snap.status == :completed
      assert snap.meta[:result] == %{pr: "https://example.com/pr/1"}
    end

    test "advance/2 after complete/2 is rejected" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :submit)
      :ok = Polecat.complete(pid)

      assert {:error, {:invalid_transition, :completed, {:advance, :design}}} =
               Polecat.advance(pid, :design)
    end

    test "fail/2 from :running transitions to :failed" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :implement)
      :ok = Polecat.fail(pid, :compile_error)

      snap = Polecat.state(pid)
      assert snap.status == :failed
      assert snap.meta[:failure_reason] == :compile_error
    end

    test "fail/2 from :awaiting also transitions to :failed" do
      {pid, _} = start_polecat()
      :ok = Polecat.advance(pid, :verify)
      :ok = Polecat.await(pid, :pr_review)
      :ok = Polecat.fail(pid, :pr_rejected)

      assert Polecat.state(pid).status == :failed
    end

    test "complete/2 from :idle is rejected" do
      {pid, _} = start_polecat()
      assert {:error, {:invalid_transition, :idle, :completed}} = Polecat.complete(pid)
    end
  end

  describe "report/3" do
    test "writes arbitrary key/value to :meta" do
      {pid, _} = start_polecat()
      :ok = Polecat.report(pid, :pr_url, "https://example.com/pr/42")
      :ok = Polecat.report(pid, :files_changed, 7)

      snap = Polecat.state(pid)
      assert snap.meta[:pr_url] == "https://example.com/pr/42"
      assert snap.meta[:files_changed] == 7
    end
  end

  describe "stop/2" do
    test "terminates the polecat and the registry forgets it" do
      {pid, bead_id} = start_polecat()
      ref = Process.monitor(pid)
      assert :ok = Polecat.stop(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert Polecat.whereis(bead_id) == nil
      assert Polecat.state(bead_id) == nil
    end

    test "stop/2 by bead_id works too" do
      {pid, bead_id} = start_polecat()
      ref = Process.monitor(pid)
      assert :ok = Polecat.stop(bead_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "stop/2 on unknown bead_id returns {:error, :not_found}" do
      assert {:error, :not_found} = Polecat.stop("nope-#{System.unique_integer()}")
    end
  end

  describe "supervisor behavior" do
    test "polecats are :temporary children — a crash does not restart them" do
      {pid, bead_id} = start_polecat()
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
      # Give the supervisor a beat to (not) restart.
      Process.sleep(50)
      assert Polecat.whereis(bead_id) == nil
    end
  end
end
