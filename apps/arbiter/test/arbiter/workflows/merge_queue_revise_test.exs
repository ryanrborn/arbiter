defmodule Arbiter.Workflows.MergeQueueReviseTest do
  @moduledoc """
  Tests for the MergeQueue's CHANGES_REQUESTED → auto-revise path (bd-95lsjb).

  Drives the `MergeQueue` with a stub revise dispatcher so the dispatch
  machinery is exercised without resuming a real worktree / spawning a Claude
  session. GitHub PR + review fetches are mocked via `Req.Test`.
  """

  # async: false — same rationale as the parent merge_queue_test.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Workflows.MergeQueue

  @token "test-token-abc123"

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => @token
      }
    }
  }

  @ws_direct %{"merge" => %{"strategy" => "direct"}}

  # ---- stub dispatcher ----------------------------------------------------

  # The MergeQueue resolves the stub by atom, so we route through :persistent_term
  # keyed on bead id (same trick the conflict-test stub uses): the test seeds a
  # target pid + canned result before driving the MergeQueue.
  defmodule StubDispatcher do
    @moduledoc false
    @behaviour Arbiter.Workflows.MergeQueue.ReviseDispatcher

    @impl true
    def dispatch(args) do
      bead_id = Map.fetch!(args, :bead_id)

      case lookup(bead_id) do
        {pid, result} ->
          send(pid, {:revise_called, args})

          case result do
            :ok -> {:ok, %{polecat_pid: pid, worktree_path: "/tmp/fake", branch: "x"}}
            other -> other
          end

        nil ->
          {:error, :no_callback_registered}
      end
    end

    def register(bead_id, pid, result \\ :ok) do
      :persistent_term.put({__MODULE__, bead_id}, {pid, result})
    end

    def unregister(bead_id) do
      :persistent_term.erase({__MODULE__, bead_id})
    end

    defp lookup(bead_id), do: :persistent_term.get({__MODULE__, bead_id}, nil)
  end

  # ---- setup --------------------------------------------------------------

  setup tags do
    workspace_config = Map.get(tags, :workspace_config, @ws_github)
    ws_name = "ws-#{System.unique_integer([:positive])}"

    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: ws_name,
        prefix: "rrv#{System.unique_integer([:positive])}",
        config: workspace_config
      })

    {:ok, bead} =
      Ash.create(Issue, %{
        title: "revise me",
        description: "bead under revise test",
        workspace_id: workspace.id
      })

    on_exit(fn -> StubDispatcher.unregister(bead.id) end)

    %{workspace: workspace, bead: bead}
  end

  defp start_merge_queue(workspace, opts \\ []) do
    name = :"merge_queue_revise_#{System.unique_integer([:positive])}"

    full_opts =
      [
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        revise_dispatcher: StubDispatcher,
        name: name
      ]
      |> Keyword.merge(opts)

    {:ok, pid} = MergeQueue.start_link(full_opts)
    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    {pid, name}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  # Adopt path: pre-seed pr_ref so enqueue slots the item straight into
  # :awaiting_approval without an open call.
  defp with_pr_ref(bead, ref) do
    {:ok, bead} = Ash.update(bead, %{pr_ref: ref}, action: :update)
    bead
  end

  # A stub serving PR get + reviews + (review) comments + issue-comment POST +
  # merge PUT. `reviews_fn`/`pr_fn` are 0-arity closures so callers can vary
  # the payload across ticks.
  defp pr_stub(n, opts) do
    reviews_fn = Keyword.fetch!(opts, :reviews)
    pr_overrides_fn = Keyword.get(opts, :pr_overrides, fn -> %{} end)
    test_pid = self()

    stub(fn conn ->
      cond do
        conn.method == "GET" and String.ends_with?(conn.request_path, "/pulls/#{n}/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(reviews_fn.())

        conn.method == "GET" and String.ends_with?(conn.request_path, "/pulls/#{n}/comments") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{n}") ->
          payload =
            Map.merge(
              %{
                "number" => n,
                "state" => "open",
                "merged" => false,
                "mergeable" => true,
                "mergeStateStatus" => "clean",
                "html_url" => "https://github.com/octo/widget/pull/#{n}"
              },
              pr_overrides_fn.()
            )

          conn |> Plug.Conn.put_status(200) |> Req.Test.json(payload)

        conn.method == "POST" and String.ends_with?(conn.request_path, "/issues/#{n}/comments") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:ack_posted, Jason.decode!(body)["body"]})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})

        conn.method == "PUT" ->
          send(test_pid, :merge_called)
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end
    end)
  end

  defp changes_requested_review(id), do: %{"id" => id, "state" => "CHANGES_REQUESTED"}

  # ---- changes-requested → single revise → awaiting_approval --------------

  describe "CHANGES_REQUESTED triggers a single revise pass" do
    test "dispatches the revise, parks :changes_requested, then returns to :awaiting_approval",
         %{workspace: ws, bead: bead} do
      bead = with_pr_ref(bead, "#901")
      StubDispatcher.register(bead.id, self(), :ok)
      pr_stub(901, reviews: fn -> [changes_requested_review(100)] end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      # Adopted straight into :awaiting_approval.
      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :awaiting_approval

      # First tick: a new CHANGES_REQUESTED review → dispatch a revise.
      :ok = MergeQueue.tick(name)

      assert_received {:revise_called, args}
      assert args.bead_id == bead.id
      assert args.workspace_id == ws.id
      assert args.pr_ref == "#901"
      assert args.target_branch == "main"
      assert is_list(args.feedback)

      # A brief acknowledging comment was posted on the PR.
      assert_received {:ack_posted, body}
      assert body =~ "review feedback"

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :changes_requested
      assert item.last_handled_review_id == 100

      # Second tick: same review id → returns to :awaiting_approval and does
      # NOT re-dispatch (debounced).
      :ok = MergeQueue.tick(name)
      refute_received {:revise_called, _}

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :awaiting_approval
      assert item.last_handled_review_id == 100
    end

    test "the same review is never actioned twice across many ticks (debounce)", %{
      workspace: ws,
      bead: bead
    } do
      bead = with_pr_ref(bead, "#902")
      StubDispatcher.register(bead.id, self(), :ok)
      pr_stub(902, reviews: fn -> [changes_requested_review(100)] end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      for _ <- 1..5, do: :ok = MergeQueue.tick(name)

      # Exactly one revise across all ticks.
      assert_received {:revise_called, _}
      refute_received {:revise_called, _}
    end

    test "a NEW CHANGES_REQUESTED review (different id) triggers a second revise", %{
      workspace: ws,
      bead: bead
    } do
      bead = with_pr_ref(bead, "#903")
      StubDispatcher.register(bead.id, self(), :ok)

      # First two reads return review 100; after that, a fresh review 300.
      counter = :counters.new(1, [:atomics])

      pr_stub(903,
        reviews: fn ->
          n = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)
          if n < 2, do: [changes_requested_review(100)], else: [changes_requested_review(300)]
        end
      )

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      :ok = MergeQueue.tick(name)
      assert_received {:revise_called, %{}}

      :ok = MergeQueue.tick(name)
      :ok = MergeQueue.tick(name)

      # The new review id dispatched a second revise.
      assert_received {:revise_called, _}

      %{items: [item]} = MergeQueue.state(name)
      assert item.last_handled_review_id == 300
    end
  end

  # ---- re-approval advances to merge --------------------------------------

  describe "a later APPROVE advances to merge" do
    test "after the revise, an APPROVE (latest verdict) merges as today", %{
      workspace: ws,
      bead: bead
    } do
      bead = with_pr_ref(bead, "#904")
      StubDispatcher.register(bead.id, self(), :ok)

      # Tick 1 read: CHANGES_REQUESTED. After that: the same reviewer APPROVED
      # (the CHANGES_REQUESTED stays in history, but the latest verdict wins).
      counter = :counters.new(1, [:atomics])

      pr_stub(904,
        reviews: fn ->
          n = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if n < 1 do
            [%{"id" => 100, "state" => "CHANGES_REQUESTED", "user" => %{"login" => "alice"}}]
          else
            [
              %{"id" => 100, "state" => "CHANGES_REQUESTED", "user" => %{"login" => "alice"}},
              %{"id" => 200, "state" => "APPROVED", "user" => %{"login" => "alice"}}
            ]
          end
        end
      )

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      :ok = MergeQueue.tick(name)
      assert_received {:revise_called, _}

      # Next tick: restores to :awaiting_approval; the APPROVE + clean CI
      # advances straight to merge.
      :ok = MergeQueue.tick(name)
      assert_received :merge_called

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  # ---- dispatch failure ---------------------------------------------------

  describe "dispatch failure" do
    test "a failed dispatch parks the item :failed (no retry loop)", %{
      workspace: ws,
      bead: bead
    } do
      bead = with_pr_ref(bead, "#905")
      StubDispatcher.register(bead.id, self(), {:error, :no_outpost})
      pr_stub(905, reviews: fn -> [changes_requested_review(100)] end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      assert_received {:revise_called, _}

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :failed
      assert match?({:revise_dispatch_failed, :no_outpost}, item.last_error)

      # A :failed item is never polled again — no second dispatch.
      :ok = MergeQueue.tick(name)
      refute_received {:revise_called, _}
    end
  end

  # ---- no-forge no-op -----------------------------------------------------

  describe "Direct (no-forge) merger" do
    @tag workspace_config: @ws_direct
    test "never dispatches a revise — the bead closes immediately", %{
      workspace: ws,
      bead: bead
    } do
      StubDispatcher.register(bead.id, self(), :ok)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      refute_received {:revise_called, _}

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end
end
