defmodule Arbiter.Accounts.ConcurrencyTest do
  @moduledoc """
  P8 (`docs/provider-account-design.md` §4.2–§4.3): the account concurrency
  ceiling, the per-workspace share, and the one authoritative `live_count/1`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  defp workspace!(name),
    do: Ash.create!(Workspace, %{name: "#{name}-#{System.unique_integer([:positive])}"})

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{slug}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp link!(ws, provider, account, attrs \\ %{}) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  # A stand-in for `Arbiter.Worker`: a process registered under the worker
  # registry carrying the same dispatch value the worker records in `init/1`.
  # Deliberately *not* a Worker — `live_count/1` must be derived from the
  # registry alone, never from anything a worker remembers.
  defp fake_worker(workspace_id, provider, opts \\ []) do
    key = Keyword.get(opts, :key, "fake-#{System.unique_integer([:positive])}")
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(WorkerRegistry, key, nil)
        :ok = WorkerRegistry.put_dispatch(key, workspace_id, provider)
        send(test, {:registered, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp kill!(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  describe "live_count/1" do
    test "counts registered workers whose workspace is metered under the account" do
      ws = workspace!("conc-live")
      account = account!(:claude, "conc-live")
      link!(ws, :claude, account)

      assert Concurrency.live_count(account) == 0

      fake_worker(ws.id, "claude")
      assert Concurrency.live_count(account) == 1

      fake_worker(ws.id, "claude")
      assert Concurrency.live_count(account) == 2
    end

    test "sums across every workspace on the account — that is the whole point" do
      account = account!(:claude, "conc-shared")
      a = workspace!("conc-a")
      b = workspace!("conc-b")
      link!(a, :claude, account)
      link!(b, :claude, account)

      fake_worker(a.id, "claude")
      fake_worker(b.id, "claude")

      assert Concurrency.live_count(account) == 2
    end

    test "ignores workers on another account, and on another provider" do
      ws = workspace!("conc-mixed")
      other_ws = workspace!("conc-other")
      claude = account!(:claude, "conc-claude")
      codex = account!(:codex, "conc-codex")
      elsewhere = account!(:claude, "conc-elsewhere")

      link!(ws, :claude, claude)
      link!(ws, :codex, codex)
      link!(other_ws, :claude, elsewhere)

      fake_worker(ws.id, "claude")
      fake_worker(ws.id, "codex")
      fake_worker(other_ws.id, "claude")

      assert Concurrency.live_count(claude) == 1
      assert Concurrency.live_count(codex) == 1
      assert Concurrency.live_count(elsewhere) == 1
    end

    test "falls back to the workspace's default provider when the dispatch named none" do
      ws = workspace!("conc-default-provider")
      account = account!(:claude, "conc-default-provider")
      link!(ws, :claude, account)

      fake_worker(ws.id, nil)

      assert Concurrency.live_count(account) == 1
    end

    test "drops when a worker process is killed — no decrement call anywhere" do
      ws = workspace!("conc-kill")
      account = account!(:claude, "conc-kill")
      link!(ws, :claude, account)

      pid = fake_worker(ws.id, "claude")
      assert Concurrency.live_count(account) == 1

      kill!(pid)

      # The registry's own cleanup is asynchronous, so the corpse row may still
      # be there. The count is still 0: it is derived from live processes.
      assert Concurrency.live_count(account) == 0
    end

    test "is 0 for a nil account" do
      assert Concurrency.live_count(nil) == 0
    end
  end

  describe "a real Arbiter.Worker registers its own dispatch" do
    test "counts toward the account, and stops counting when killed" do
      ws = workspace!("real-worker")
      account = account!(:claude, "real-worker")
      link!(ws, :claude, account)

      {:ok, task} = Ash.create(Arbiter.Tasks.Issue, %{title: "ship it", workspace_id: ws.id})

      {:ok, pid} =
        Arbiter.Worker.start(
          task_id: task.id,
          repo: "test/repo",
          workspace_id: ws.id,
          meta: %{provider: "claude"}
        )

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      assert Concurrency.live_count(account) == 1
      assert Concurrency.headroom(ws.id, :claude) == :unlimited

      kill!(pid)

      assert Concurrency.live_count(account) == 0
    end
  end

  describe "account_headroom/2 (§4.2)" do
    test "is :unlimited when the workspace has no account" do
      ws = workspace!("hr-none")
      assert Concurrency.account_headroom(nil, ws) == :unlimited
    end

    test "is :unlimited when neither the ceiling nor the share is set (§4.4 default)" do
      ws = workspace!("hr-optin")
      account = account!(:claude, "hr-optin")
      link!(ws, :claude, account)

      fake_worker(ws.id, "claude")

      assert Concurrency.account_headroom(account, ws) == :unlimited
    end

    test "max(0, max_concurrent - live_count) when only the ceiling is set" do
      ws = workspace!("hr-ceiling")
      account = account!(:claude, "hr-ceiling", %{max_concurrent: 4})
      link!(ws, :claude, account)

      assert Concurrency.account_headroom(account, ws) == 4

      fake_worker(ws.id, "claude")
      assert Concurrency.account_headroom(account, ws) == 3
    end

    test "the share caps below the ceiling" do
      ws = workspace!("hr-share")
      account = account!(:claude, "hr-share", %{max_concurrent: 4})
      link!(ws, :claude, account, %{share: 2})

      assert Concurrency.account_headroom(account, ws) == 2

      fake_worker(ws.id, "claude")
      assert Concurrency.account_headroom(account, ws) == 1
    end

    test "the share alone bounds when the account has no ceiling" do
      ws = workspace!("hr-share-only")
      account = account!(:claude, "hr-share-only")
      link!(ws, :claude, account, %{share: 2})

      assert Concurrency.account_headroom(account, ws) == 2
    end

    test "never goes negative" do
      ws = workspace!("hr-floor")
      account = account!(:claude, "hr-floor", %{max_concurrent: 1})
      link!(ws, :claude, account)

      fake_worker(ws.id, "claude")
      fake_worker(ws.id, "claude")

      assert Concurrency.account_headroom(account, ws) == 0
    end

    test "a sibling workspace's live workers consume this workspace's headroom" do
      account = account!(:claude, "hr-sibling", %{max_concurrent: 2})
      mine = workspace!("hr-mine")
      theirs = workspace!("hr-theirs")
      link!(mine, :claude, account, %{share: 2})
      link!(theirs, :claude, account, %{share: 2})

      fake_worker(theirs.id, "claude")
      fake_worker(theirs.id, "claude")

      assert Concurrency.account_headroom(account, mine) == 0
    end

    test "accepts a workspace id as well as a workspace struct" do
      ws = workspace!("hr-by-id")
      account = account!(:claude, "hr-by-id", %{max_concurrent: 3})
      link!(ws, :claude, account, %{share: 2})

      assert Concurrency.account_headroom(account, ws.id) == 2
    end
  end

  describe "shares are caps, not reservations (§4.3)" do
    test "shares may sum to more than the ceiling — by design, no error" do
      account = account!(:claude, "cap-not-reservation", %{max_concurrent: 4})

      workspaces =
        for name <- ~w(share-a share-b share-c) do
          ws = workspace!(name)
          link!(ws, :claude, account, %{share: 3})
          ws
        end

      # 3 + 3 + 3 = 9 > 4. Nothing rejects it, and each workspace sees its own
      # cap until the account ceiling binds.
      for ws <- workspaces do
        assert Concurrency.account_headroom(account, ws) == 3
      end

      # The ceiling is the hard stop: four live workers anywhere on the account
      # take every workspace to zero even though each is "entitled" to 3.
      one = hd(workspaces)
      for _ <- 1..4, do: fake_worker(one.id, "claude")

      for ws <- workspaces do
        assert Concurrency.account_headroom(account, ws) == 0
      end
    end
  end

  describe "headroom/2 (workspace + provider convenience)" do
    test "resolves the account from the workspace link" do
      ws = workspace!("conv-hr")
      account = account!(:claude, "conv-hr", %{max_concurrent: 2})
      link!(ws, :claude, account)

      assert Concurrency.headroom(ws.id, :claude) == 2
    end

    test "is :unlimited when the workspace is not linked to any account" do
      ws = workspace!("conv-unlinked")
      assert Concurrency.headroom(ws.id, :claude) == :unlimited
      assert Concurrency.headroom(nil, :claude) == :unlimited
    end
  end
end
