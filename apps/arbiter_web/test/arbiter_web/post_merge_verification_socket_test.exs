defmodule ArbiterWeb.PostMergeVerificationSocketTest do
  @moduledoc """
  bd-9so315, acceptance criterion 6 — the post-merge verification loop observed
  over a **real HTTP listener**, not `Phoenix.ConnTest`.

  Criterion 6 asks for a restart-and-observe against a running server. The
  production coordinator cannot supply it (it runs pre-migration `main`, and
  restarting it tears down every in-flight worker), and this worker is
  forbidden from booting a server process of its own. What is reachable, and
  what this test does, is to stand the real endpoint up on a real socket inside
  the test VM and drive the whole loop across it:

    1. a `verify_after_deploy` task is created by `POST /api/issues` over TCP —
       the exact wire request `arb issue create --verify-after-deploy` sends;
    2. the real `Arbiter.Workflows.MergeQueue` GenServer merges its PR;
    3. `GET /api/issues/:id` over TCP reports `awaiting_verification`, and the
       coordinator has exactly one escalation naming the boot-vs-merge question;
    4. `POST /api/issues/:id/verify` over TCP — byte-for-byte the request
       `ArbiterCli.Cmd.Verify` builds (`%{"outcome" => _, "evidence" => _}`,
       asserted on the wire in `ArbiterCli.Cmd.VerifyTest`) — closes the task;
    5. a fresh `GET` confirms the evidence is durable, not just echoed.

  Unlike the `ConnCase` coverage, every step here crosses a socket into a
  separate request process: Bandit, the endpoint plug pipeline, JSON
  encode/decode and the DB checkout all run for real. The test prints a
  transcript so the run can be pasted as the recorded observation.
  """
  # async: false — the sandbox connection must be shared with the MergeQueue
  # GenServer and with Bandit's request processes.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue

  defmodule FakeWorktree do
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
    def rebase_onto_origin(_path, _branch), do: {:ok, :up_to_date}
  end

  @pr_number 9315

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123"
      }
    }
  }

  setup do
    # `port: 0` lets the kernel pick a free port and hand it straight to the
    # listener, then we read the bound port back off Thousand Island. Probing for
    # a free port first and rebinding it leaves a window in which a sibling VM on
    # this host can take it (`:eaddrinuse` would raise out of `start_supervised!`).
    listener =
      start_supervised!(
        {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: "socket-verify-#{System.unique_integer([:positive])}",
        prefix: "sv#{System.unique_integer([:positive])}",
        config: @ws_github
      })

    %{base: "http://127.0.0.1:#{port}", workspace: workspace}
  end

  test "a flagged task parks on merge and closes on a verdict, all over a real socket",
       %{base: base, workspace: ws} do
    log("listener up at #{base}")

    # ---- 1. create the flagged task over the wire ------------------------
    created =
      request!(:post, base <> "/api/issues", %{
        "title" => "post-merge verification rehearsal",
        "description" => "bd-9so315 criterion 6",
        "workspace_id" => ws.id,
        "verify_after_deploy" => true
      })

    assert created.status == 201
    assert created.body["verify_after_deploy"] == true
    assert created.body["status"] == "open"
    id = created.body["id"]
    log("POST /api/issues -> 201 #{id} verify_after_deploy=true")

    # ---- 2. merge it through the real merge queue ------------------------
    stub_forge(@pr_number)
    {_pid, name} = start_merge_queue(ws)
    :ok = MergeQueue.enqueue(name, id)
    :ok = MergeQueue.tick(name)
    log("MergeQueue merged PR ##{@pr_number}")

    # ---- 3. the server reports the park over the wire --------------------
    parked = request!(:get, base <> "/api/issues/" <> id)

    assert parked.status == 200
    assert parked.body["status"] == "awaiting_verification"
    assert is_binary(parked.body["awaiting_verification_at"])
    assert parked.body["verification_outcome"] == nil

    log(
      "GET /api/issues/#{id} -> status=awaiting_verification " <>
        "awaiting_verification_at=#{parked.body["awaiting_verification_at"]}"
    )

    assert [escalation] = Message.inbox("coordinator", workspace_id: ws.id)
    assert escalation.kind == :escalation
    assert escalation.directive_ref == id
    assert escalation.body =~ "restart"
    # The VM serving this socket booted before the merge, so the notification
    # must say a restart is required before the observation counts.
    assert escalation.body =~ "booted before"
    assert escalation.body =~ "arb issue verify #{id}"
    log("coordinator inbox: 1 escalation — #{escalation.subject}")
    log("escalation body:\n" <> indent(escalation.body))

    # ---- 4. record the verdict over the wire -----------------------------
    evidence =
      "live-socket rehearsal: task parked at awaiting_verification after the " <>
        "merge queue merged PR ##{@pr_number}; verdict recorded through " <>
        "POST /api/issues/:id/verify on #{base}"

    # The exact body ArbiterCli.Cmd.Verify puts on the wire for
    # `arb issue verify <id> --observed "<evidence>"`.
    verified =
      request!(:post, base <> "/api/issues/" <> id <> "/verify", %{
        "outcome" => "observed",
        "evidence" => evidence
      })

    assert verified.status == 200
    assert verified.body["status"] == "closed"
    assert verified.body["verification_outcome"] == "observed"
    assert verified.body["verification_evidence"] == evidence
    log("POST /api/issues/#{id}/verify {observed} -> 200 status=closed")

    # ---- 5. the evidence is durable, not echoed --------------------------
    reread = request!(:get, base <> "/api/issues/" <> id)

    assert reread.body["status"] == "closed"
    assert reread.body["verification_outcome"] == "observed"
    assert reread.body["verification_evidence"] == evidence
    assert is_binary(reread.body["closed_at"])
    log("GET /api/issues/#{id} -> closed, evidence persisted")
  end

  test "an unflagged task still closes on merge, over the same socket",
       %{base: base, workspace: ws} do
    created =
      request!(:post, base <> "/api/issues", %{
        "title" => "unflagged regression",
        "workspace_id" => ws.id
      })

    assert created.body["verify_after_deploy"] == false
    id = created.body["id"]

    stub_forge(@pr_number + 1)
    {_pid, name} = start_merge_queue(ws)
    :ok = MergeQueue.enqueue(name, id)
    :ok = MergeQueue.tick(name)

    closed = request!(:get, base <> "/api/issues/" <> id)

    assert closed.body["status"] == "closed"
    assert closed.body["awaiting_verification_at"] == nil
    assert Message.inbox("coordinator", workspace_id: ws.id) == []
    log("unflagged task #{id} closed on merge, coordinator inbox empty")
  end

  # ---- helpers -----------------------------------------------------------

  defp request!(method, url, body \\ nil) do
    opts =
      [method: method, url: url, retry: false, receive_timeout: 10_000] ++
        if(body, do: [json: body], else: [])

    Req.request!(opts)
  end

  defp start_merge_queue(workspace) do
    name = :"socket_merge_queue_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        name: name,
        worktree_module: FakeWorktree
      )

    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    {pid, name}
  end

  defp stub_forge(number) do
    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      cond do
        conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => number,
            "html_url" => "https://github.com/octo/widget/pull/#{number}"
          })

        conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

        conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{number}") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "number" => number,
            "state" => "open",
            "mergeable" => true,
            "mergeStateStatus" => "clean",
            "html_url" => "https://github.com/octo/widget/pull/#{number}"
          })

        conn.method == "PUT" and String.ends_with?(conn.request_path, "/merge") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"merged" => true, "sha" => "deadbeef"})

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)
  end

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  defp log(line), do: IO.puts("[bd-9so315 live socket] " <> line)
end
