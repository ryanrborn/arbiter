defmodule Arbiter.Board.SnapshotAccountCeilingTest do
  @moduledoc """
  P8 (`docs/provider-account-design.md` §4.2): the board must not advertise
  slots the account ceiling will refuse. `slots_total` is what every Ready
  card's "will this be picked up?" position is computed from, so a board that
  ignores the ceiling lies in exactly the situation the ceiling exists for.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Workspace

  defp workspace! do
    Ash.create!(Workspace, %{
      name: "board-ceiling-#{System.unique_integer([:positive])}",
      prefix: "bc#{System.unique_integer([:positive])}",
      config: %{"conductor" => %{"max_concurrent" => 6}}
    })
  end

  defp account!(attrs) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: :claude, slug: "board-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp link!(ws, account, attrs \\ %{}) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: :claude, provider_account_id: account.id},
        attrs
      )
    )
  end

  defp live_worker!(ws) do
    key = "board-worker-#{System.unique_integer([:positive])}"
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Arbiter.Worker.Registry, key, nil)
        :ok = Arbiter.Worker.Registry.put_dispatch(key, ws.id, "claude")
        send(test, {:registered, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  describe "effective_max_concurrent/1" do
    test "is the workspace × system min when the account has no ceiling (§4.4)" do
      ws = workspace!()
      link!(ws, account!(%{}))
      live_worker!(ws)

      assert Snapshot.effective_max_concurrent(ws.id) == 6
    end

    test "the account ceiling caps below the workspace cap" do
      ws = workspace!()
      link!(ws, account!(%{max_concurrent: 2}))

      assert Snapshot.effective_max_concurrent(ws.id) == 2
    end

    test "the workspace share caps below the account ceiling" do
      ws = workspace!()
      link!(ws, account!(%{max_concurrent: 4}), %{share: 1})

      assert Snapshot.effective_max_concurrent(ws.id) == 1
    end

    test "a sibling workspace's live workers shrink the slots this board shows" do
      account = account!(%{max_concurrent: 3})
      mine = workspace!()
      theirs = workspace!()
      link!(mine, account)
      link!(theirs, account)

      assert Snapshot.effective_max_concurrent(mine.id) == 3

      live_worker!(theirs)
      live_worker!(theirs)

      assert Snapshot.effective_max_concurrent(mine.id) == 1
    end

    test "this workspace's own live workers are not double-counted" do
      ws = workspace!()
      link!(ws, account!(%{max_concurrent: 3}))

      # Two of the account's three slots are held by this workspace. The board
      # still advertises a total of 3 — `slots_free` is what subtracts the two
      # running cards, and subtracting them here as well would report 1.
      live_worker!(ws)
      live_worker!(ws)

      assert Snapshot.effective_max_concurrent(ws.id) == 3
    end

    test "a full account reports zero slots rather than lying" do
      ws = workspace!()
      account = account!(%{max_concurrent: 1})
      theirs = workspace!()
      link!(ws, account)
      link!(theirs, account)

      live_worker!(theirs)

      assert Snapshot.effective_max_concurrent(ws.id) == 0
    end

    test "a nil workspace is still the system max" do
      assert Snapshot.effective_max_concurrent(nil) == Snapshot.system_max_concurrent()
    end
  end

  describe "load/1" do
    test "slots_total reflects the account ceiling" do
      ws = workspace!()
      link!(ws, account!(%{max_concurrent: 2}))

      board = Snapshot.load(workspace_id: ws.id, issues: [], workers: [], deps: [])

      assert board.slots_total == 2
    end
  end
end
