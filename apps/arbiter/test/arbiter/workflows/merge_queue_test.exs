defmodule Arbiter.Workflows.MergeQueueTest do
  # async: false — DataCase sandbox can't be shared with the GenServer process
  # in async mode.
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat.TargetBranch
  alias Arbiter.Polecats.Run
  alias Arbiter.Workflows.MergeQueue

  # Stub worktree module used in tests — avoids real filesystem git calls.
  defmodule FakeWorktree do
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:ok, ""}
  end

  defmodule FailingWorktree do
    def worktree_path(branch), do: "/fake/worktrees/#{branch}"
    def push(_path, _opts), do: {:error, {:git_failed, "fatal: repository not found"}}
  end

  @token "test-token-abc123"

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

  @ws_github_squash %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123",
        "merge_method" => "squash"
      }
    }
  }

  @ws_github_merge %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123",
        "merge_method" => "merge"
      }
    }
  }

  @ws_github_rebase %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "test-token-abc123",
        "merge_method" => "rebase"
      }
    }
  }

  @ws_direct %{"merge" => %{"strategy" => "direct"}}

  # ---- setup helpers ------------------------------------------------------

  setup tags do
    workspace_config = Map.get(tags, :workspace_config, %{})
    ws_name = "ws-#{System.unique_integer([:positive])}"

    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: ws_name,
        prefix: "rt#{System.unique_integer([:positive])}",
        config: workspace_config
      })

    {:ok, bead} =
      Ash.create(Issue, %{
        title: "merge me",
        description: "body",
        workspace_id: workspace.id
      })

    %{workspace: workspace, bead: bead}
  end

  defp start_merge_queue(workspace, opts \\ []) do
    name = :"merge_queue_#{System.unique_integer([:positive])}"

    full_opts =
      [
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        name: name,
        worktree_module: FakeWorktree
      ]
      |> Keyword.merge(opts)

    {:ok, pid} = MergeQueue.start_link(full_opts)
    # Allow the merge_queue process to use the Mergers.Github Req.Test stub.
    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), pid)
    # Allow it to use the Ecto sandbox connection too.
    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    {pid, name}
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  # Raw GitHub PR payload for the GET /pulls/{N} endpoint.
  defp pr_payload(overrides) do
    Map.merge(
      %{
        "number" => 42,
        "state" => "open",
        "mergeable" => true,
        "mergeStateStatus" => "clean",
        "html_url" => "https://github.com/octo/widget/pull/42"
      },
      overrides
    )
  end

  # Reviews response for the GET /pulls/{N}/reviews endpoint.
  defp reviews_payload(state) do
    [%{"state" => state}]
  end

  # Set up a full-cycle stub that responds to open, get (PR + reviews), and
  # merge requests. `pr_number` controls which PR number to open; `pr_overrides`
  # are merged into the PR GET payload; `reviews_state` controls the review state.
  defp full_cycle_stub(pr_number, pr_overrides \\ %{}, reviews_state \\ "APPROVED") do
    test_pid = self()
    number = pr_number

    stub(fn conn ->
      cond do
        conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => number,
            "html_url" => "https://github.com/octo/widget/pull/#{number}"
          })

        conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(reviews_payload(reviews_state))

        conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{number}") ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(pr_payload(%{"number" => number} |> Map.merge(pr_overrides)))

        conn.method == "PUT" and String.ends_with?(conn.request_path, "/merge") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          send(test_pid, {:merge_called, decoded["merge_method"]})

          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"merged" => true, "sha" => "deadbeef"})

        true ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
      end
    end)
  end

  # ---- tests --------------------------------------------------------------

  describe "start_link/1" do
    test "starts with a workspace_id", %{workspace: ws} do
      {pid, _name} = start_merge_queue(ws)
      assert Process.alive?(pid)
    end

    test "raises without workspace_id" do
      assert_raise ArgumentError, ~r/workspace_id/, fn ->
        Process.flag(:trap_exit, true)
        {:error, {%ArgumentError{message: msg}, _}} = MergeQueue.start_link([])
        raise ArgumentError, msg
      end
    end
  end

  describe "enqueue/2 with strategy=github" do
    @tag workspace_config: @ws_github
    test "opens a PR via adapter.open and queues with status :awaiting_approval", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()

      stub(fn conn ->
        if conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") do
          send(test_pid, :pr_open_called)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 101, "state" => "open"})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
        end
      end)

      {_pid, name} = start_merge_queue(ws)
      assert :ok = MergeQueue.enqueue(name, bead.id)
      assert_received :pr_open_called

      %{items: [item]} = MergeQueue.state(name)
      assert item.bead_id == bead.id
      assert item.mr_ref == "#101"
      assert item.status == :awaiting_approval
      assert item.strategy == "github"
    end

    @tag workspace_config: @ws_github
    test "records mr_ref on the bead's pr_ref", %{workspace: ws, bead: bead} do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 77})
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.pr_ref == "#77"
    end

    @tag workspace_config: @ws_github
    test "writes pr_ref even when tracker_ref is already set (issue ref preserved)", %{
      workspace: ws,
      bead: bead
    } do
      {:ok, bead} = Ash.update(bead, %{tracker_ref: "PRE-123"}, action: :update)

      stub(fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 77})
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.tracker_ref == "PRE-123"
      assert reloaded.pr_ref == "#77"
    end

    @tag workspace_config: @ws_github
    test "adapter.open failure → status :failed; bead is not modified", %{
      workspace: ws,
      bead: bead
    } do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      {_pid, name} = start_merge_queue(ws)
      {:error, _} = MergeQueue.enqueue(name, bead.id)

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :failed
      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end

    @tag workspace_config: @ws_github
    test "push failure → status :failed with {:push_failed, reason}; adapter.open never called",
         %{workspace: ws, bead: bead} do
      test_pid = self()

      stub(fn conn ->
        if conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") do
          send(test_pid, :pr_open_called)
        end

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 1})
      end)

      {_pid, name} = start_merge_queue(ws, worktree_module: FailingWorktree)
      {:error, {:push_failed, _reason}} = MergeQueue.enqueue(name, bead.id)

      refute_received :pr_open_called

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :failed
      assert match?({:push_failed, _}, item.last_error)

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end
  end

  describe "enqueue/2 PR base resolution (bd-b6rzoc)" do
    # GitHub workspace whose repo defaults to an integration branch (object form).
    @ws_github_repo %{
      "merge" => %{
        "strategy" => "github",
        "config" => %{
          "owner" => "octo",
          "repo" => "widget",
          "credentials_ref" => "test-token-abc123"
        }
      },
      "repo_paths" => %{
        "dolphin/repo" => %{"path" => "/tmp", "target_branch" => "integration/dolphin"}
      }
    }

    # Capture the `base` field of the POST /pulls payload and ACK with a PR.
    defp capture_base_stub(test_pid) do
      stub(fn conn ->
        if conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:pr_base, Jason.decode!(body)["base"]})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 101, "state" => "open"})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
        end
      end)
    end

    defp record_run(bead, repo) do
      {:ok, _run} =
        Ash.create(Run, %{
          bead_id: bead.id,
          repo: repo,
          workspace_id: bead.workspace_id,
          status: :completed,
          started_at: DateTime.utc_now()
        })

      :ok
    end

    @tag workspace_config: @ws_github
    test "per-bead target_branch wins even when the queue's state.base differs", %{
      workspace: ws,
      bead: bead
    } do
      {:ok, bead} = Ash.update(bead, %{target_branch: "dolphin"}, action: :update)
      capture_base_stub(self())

      # Queue base is "main" (start_merge_queue default) — the bead must still win.
      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_base, "dolphin"}
    end

    @tag workspace_config: @ws_github_repo
    test "repo-level target_branch sets the PR base AND matches the worktree base", %{
      workspace: ws,
      bead: bead
    } do
      # The bead was worked in dolphin/repo — recorded on its polecat run, exactly
      # the repo Dispatch cut the worktree with.
      :ok = record_run(bead, "dolphin/repo")
      capture_base_stub(self())

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_base, pr_base}
      assert pr_base == "integration/dolphin"

      # Invariant: the worktree base Dispatch would compute for this bead (same
      # shared resolver, same repo) is identical to the PR base.
      {:ok, bead} = Ash.load(bead, [:workspace])
      worktree_base = TargetBranch.resolve(bead, repo: "dolphin/repo")
      assert worktree_base == pr_base
    end

    @tag workspace_config: @ws_github
    test "default-workspace bead with no overrides targets main", %{workspace: ws, bead: bead} do
      capture_base_stub(self())

      # No explicit queue base, no bead target, no repo default, no merge.base.
      {_pid, name} = start_merge_queue(ws, base: nil)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_base, "main"}
    end
  end

  describe "enqueue/2 PR body source (bd-53xrmi)" do
    # Capture the `body` field of the POST /pulls payload and ACK with a PR.
    defp capture_body_stub(test_pid) do
      stub(fn conn ->
        if conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") do
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:pr_body, Jason.decode!(body)["body"]})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 101, "state" => "open"})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
        end
      end)
    end

    @tag workspace_config: @ws_github
    test "opens with the worker-authored pr_body when present", %{workspace: ws, bead: bead} do
      worker_body = "## Summary\nDid the thing.\n\n## Test plan\n- [x] mix test"
      {:ok, bead} = Ash.update(bead, %{pr_body: worker_body}, action: :update)
      capture_body_stub(self())

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_body, ^worker_body}
    end

    @tag workspace_config: @ws_github
    test "pr_body wins over the bead description", %{workspace: ws, bead: bead} do
      {:ok, bead} =
        Ash.update(bead, %{description: "ticket spec", pr_body: "real writeup"}, action: :update)

      capture_body_stub(self())

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_body, "real writeup"}
    end

    @tag workspace_config: @ws_github
    test "falls back to the bead description when no pr_body", %{workspace: ws, bead: bead} do
      # setup creates the bead with description: "body" and no pr_body.
      capture_body_stub(self())

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_body, "body"}
    end

    # Regression for #3606: an empty/blank description with no pr_body used to
    # send "" as the PR body, and GitHub then injects the repo's bare PR
    # template. The body must NEVER be empty — it falls back to a generated
    # default that always carries the title.
    @tag workspace_config: @ws_github
    test "blank description + no pr_body → non-empty default body (not empty)", %{
      workspace: ws,
      bead: bead
    } do
      {:ok, bead} = Ash.update(bead, %{description: "", pr_body: ""}, action: :update)
      capture_body_stub(self())

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_body, sent_body}
      assert sent_body != ""
      # default_body renders the title as a Markdown heading.
      assert sent_body =~ "## merge me"
    end

    @tag workspace_config: @ws_github
    test "whitespace-only pr_body is treated as absent (falls through)", %{
      workspace: ws,
      bead: bead
    } do
      {:ok, bead} =
        Ash.update(bead, %{description: "the spec", pr_body: "   \n  "}, action: :update)

      capture_body_stub(self())

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:pr_body, "the spec"}
    end
  end

  describe "enqueue/2 no-duplicate-MR guard (bd-auma3z)" do
    @tag workspace_config: @ws_github
    test "adopts an existing open MR ref instead of opening a duplicate", %{
      workspace: ws,
      bead: bead
    } do
      # Simulate a resumed bead whose prior worker already opened PR #55.
      {:ok, bead} = Ash.update(bead, %{pr_ref: "#55"}, action: :update)

      test_pid = self()

      stub(fn conn ->
        if conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") do
          send(test_pid, :pr_open_called)
        end

        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 999})
      end)

      {_pid, name} = start_merge_queue(ws)
      assert :ok = MergeQueue.enqueue(name, bead.id)

      # No open call — the existing MR was adopted, not duplicated.
      refute_received :pr_open_called

      %{items: [item]} = MergeQueue.state(name)
      assert item.mr_ref == "#55"
      assert item.status == :awaiting_approval

      # The bead's pr_ref is unchanged.
      assert Ash.get!(Issue, bead.id).pr_ref == "#55"
    end
  end

  describe "enqueue/2 MR remote-link on the upstream tracker" do
    @jira_env "GTE_REFINERY_JIRA_TOKEN"
    @ws_github_jira %{
      "merge" => %{
        "strategy" => "github",
        "config" => %{
          "owner" => "octo",
          "repo" => "widget",
          "credentials_ref" => @token
        }
      },
      "tracker" => %{
        "type" => "jira",
        "config" => %{
          "host" => "leotechnologies.atlassian.net",
          "project_key" => "VR",
          "credentials_ref" => "env:GTE_REFINERY_JIRA_TOKEN",
          "email" => "tester@example.com"
        }
      }
    }

    setup do
      System.put_env(@jira_env, "test-jira-token")
      on_exit(fn -> System.delete_env(@jira_env) end)
      :ok
    end

    @tag workspace_config: @ws_github_jira
    test "posts a Jira remote link pointing at the opened MR", %{workspace: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "jira-backed",
          tracker_type: :jira,
          tracker_ref: "VR-17585",
          skip_upstream_create: true,
          workspace_id: ws.id
        })

      test_pid = self()

      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "number" => 88,
          "html_url" => "https://github.com/octo/widget/pull/88"
        })
      end)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:jira_remotelink, conn.request_path, Jason.decode!(body)})
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
      end)

      {pid, name} = start_merge_queue(ws)
      Req.Test.allow(Arbiter.Trackers.Jira.HTTP, self(), pid)

      :ok = MergeQueue.enqueue(name, bead.id)

      assert_receive {:jira_remotelink, "/rest/api/3/issue/VR-17585/remotelink", payload}
      assert payload["object"]["url"] == "https://github.com/octo/widget/pull/88"
    end
  end

  describe "enqueue/2 with strategy=direct" do
    @tag workspace_config: @ws_direct
    test "never calls adapter APIs and closes the bead immediately", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:unexpected_api_call, conn.method, conn.request_path})
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      refute_received {:unexpected_api_call, _, _}

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  describe ":tick polling" do
    @tag workspace_config: @ws_github_squash
    test "approved + ci_clean → merges with squash and closes the bead", %{
      workspace: ws,
      bead: bead
    } do
      full_cycle_stub(50)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :awaiting_approval

      :ok = MergeQueue.tick(name)

      assert_received {:merge_called, "squash"}

      # After tick, the item is removed (poll_all prunes :done items).
      %{items: items} = MergeQueue.state(name)
      assert items == []

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :closed
    end

    @tag workspace_config: @ws_github
    test "not approved → stays in :awaiting_approval and does not merge", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()
      pr_number = 60

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => pr_number})

          conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
            # No approvals, changes requested
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json([%{"state" => "CHANGES_REQUESTED"}])

          conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{pr_number}") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(
              pr_payload(%{"number" => pr_number, "mergeStateStatus" => "blocked"})
            )

          conn.method == "PUT" ->
            send(test_pid, :unexpected_merge)
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      refute_received :unexpected_merge

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :awaiting_approval

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end

    @tag workspace_config: @ws_github
    test "conflicting MR → spawns conflict resolver (not a plain merge)", %{
      workspace: ws,
      bead: bead
    } do
      test_pid = self()
      pr_number = 70

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => pr_number})

          conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

          conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{pr_number}") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(
              pr_payload(%{
                "number" => pr_number,
                "mergeable" => false,
                "mergeStateStatus" => "dirty"
              })
            )

          conn.method == "PUT" ->
            send(test_pid, :unexpected_merge)
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      # The item must NOT have been merged.
      refute_received :unexpected_merge

      # The conflict resolver path parks the item; the exact status depends on
      # whether the resolver successfully spawns (it won't in test without a repo,
      # so it'll be :failed or :conflict_resolving). Either way, it's not :closed.
      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end

    @tag workspace_config: @ws_github
    test "adapter.merge failure → status :failed; bead is NOT closed", %{
      workspace: ws,
      bead: bead
    } do
      pr_number = 80

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => pr_number})

          conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

          conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{pr_number}") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(pr_payload(%{"number" => pr_number}))

          conn.method == "PUT" ->
            conn
            |> Plug.Conn.put_status(409)
            |> Req.Test.json(%{"message" => "Pull Request is not mergeable"})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :failed

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :open
    end
  end

  # bd-d1jp4r: when the Watchdog merges a PR before the MergeQueue processes the
  # {:polecat_done, bead_id} event, advance_status must close the bead on the
  # first tick rather than stalling at :awaiting_approval forever. This happens
  # because a merged GitHub PR returns status: :merged but no GitHub review
  # (the ReviewGate approved in-process), so approved: false and ci_clean: false.
  describe "already-merged MR (bd-d1jp4r)" do
    @tag workspace_config: @ws_github
    test "tick closes the bead when the polled PR is already merged", %{
      workspace: ws,
      bead: bead
    } do
      pr_number = 91
      test_pid = self()

      # Simulate a bead whose Watchdog already merged the PR: the pr_ref is set
      # on the bead and the GitHub API returns merged: true with no reviews.
      {:ok, bead} = Ash.update(bead, %{pr_ref: "##{pr_number}"}, action: :update)

      stub(fn conn ->
        cond do
          conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
            # No GitHub reviews — ReviewGate approved in-process only.
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

          conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{pr_number}") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(
              pr_payload(%{
                "number" => pr_number,
                "state" => "closed",
                "merged" => true,
                "merged_at" => "2026-06-17T20:59:45Z",
                "mergeStateStatus" => "UNKNOWN"
              })
            )

          conn.method == "PUT" ->
            send(test_pid, :unexpected_merge_call)
            conn |> Plug.Conn.put_status(405) |> Req.Test.json(%{"message" => "already merged"})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "unexpected"})
        end
      end)

      {_pid, name} = start_merge_queue(ws)

      # adopt_existing_mr enqueues without opening (bead already has pr_ref).
      :ok = MergeQueue.enqueue(name, bead.id)

      %{items: [item]} = MergeQueue.state(name)
      assert item.status == :awaiting_approval
      assert item.mr_ref == "##{pr_number}"

      # On tick: adapter.get returns status: :merged → close bead, no merge API call.
      :ok = MergeQueue.tick(name)

      refute_received :unexpected_merge_call,
                      "adapter.merge should NOT be called for already-merged PR"

      # Item is removed (poll_all prunes :done items).
      %{items: items} = MergeQueue.state(name)
      assert items == []

      reloaded = Ash.get!(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  describe "merge_method mapping" do
    @tag workspace_config: @ws_github_squash
    test "merge_method=squash → adapter sends squash", %{workspace: ws, bead: bead} do
      assert_merge_method_called("squash", ws, bead)
    end

    @tag workspace_config: @ws_github_merge
    test "merge_method=merge → adapter sends merge", %{workspace: ws, bead: bead} do
      assert_merge_method_called("merge", ws, bead)
    end

    @tag workspace_config: @ws_github_rebase
    test "merge_method=rebase → adapter sends rebase", %{workspace: ws, bead: bead} do
      assert_merge_method_called("rebase", ws, bead)
    end

    defp assert_merge_method_called(expected_method, ws, bead) do
      test_pid = self()
      pr_number = 90

      stub(fn conn ->
        cond do
          conn.method == "POST" and String.ends_with?(conn.request_path, "/pulls") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => pr_number})

          conn.method == "GET" and String.ends_with?(conn.request_path, "/reviews") ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([%{"state" => "APPROVED"}])

          conn.method == "GET" and String.contains?(conn.request_path, "/pulls/#{pr_number}") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(pr_payload(%{"number" => pr_number}))

          conn.method == "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            send(test_pid, {:merge_method, decoded["merge_method"]})
            conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"merged" => true})

          true ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      assert_received {:merge_method, ^expected_method}
    end
  end

  describe "PubSub" do
    @tag workspace_config: @ws_github
    test "{:polecat_done, bead_id} message triggers enqueue", %{workspace: ws, bead: bead} do
      test_pid = self()

      stub(fn conn ->
        if conn.method == "POST" do
          send(test_pid, :pr_open_called)
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 111})
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      {pid, _name} = start_merge_queue(ws)
      send(pid, {:polecat_done, bead.id})

      assert_receive :pr_open_called, 500

      :sys.get_state(pid)
      %{items: [item]} = MergeQueue.state(pid)
      assert item.bead_id == bead.id
      assert item.mr_ref == "#111"
    end

    @tag workspace_config: @ws_github
    test "broadcasts {:bead_closed_by_merge_queue, bead_id} when merge lands", %{
      workspace: ws,
      bead: bead
    } do
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "merge_queue:" <> ws.id)

      pr_number = 200
      full_cycle_stub(pr_number)

      {_pid, name} = start_merge_queue(ws)
      :ok = MergeQueue.enqueue(name, bead.id)
      :ok = MergeQueue.tick(name)

      bead_id = bead.id
      assert_receive {:bead_closed_by_merge_queue, ^bead_id}, 500
    end
  end
end
