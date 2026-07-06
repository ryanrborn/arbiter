defmodule Arbiter.Trackers.SyncTest do
  @moduledoc """
  Tests for the loud, escalation-raising tracker lifecycle orchestration
  (`Arbiter.Trackers.Sync`) — the layer that drives the real VR workflow:

    * PR-open -> In Code Review + a PR-link comment + a remote link.
    * ReviewGate-approved-but-parked -> Pending Merge.
    * A genuine sync failure surfaces loudly as an escalation (the
      VR-17911 silent-failure regression guard).

  Jira HTTP is stubbed via `Req.Test` (`:jira_http_stub` is true in test env).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Messages.Message
  alias Arbiter.Trackers.Sync

  @ref "VR-17585"
  @env "GTE_TRACKER_SYNC_JIRA_TOKEN"

  setup do
    System.put_env(@env, "test-jira-token")
    on_exit(fn -> System.delete_env(@env) end)
    :ok
  end

  defp jira_workspace(status_map) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "jira-ws-#{System.unique_integer([:positive])}",
        prefix: "jr",
        config: %{
          "tracker" => %{
            "type" => "jira",
            "config" => %{
              "host" => "leotechnologies.atlassian.net",
              "project_key" => "VR",
              "credentials_ref" => "env:#{@env}",
              "email" => "tester@example.com",
              "status_map" => status_map
            }
          }
        }
      })

    ws
  end

  defp jira_issue(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(
          %{
            title: "tracked",
            tracker_type: :jira,
            tracker_ref: @ref,
            skip_upstream_create: true,
            workspace_id: ws.id
          },
          attrs
        )
      )

    issue
  end

  defp escalations_for(ws_id) do
    Message
    |> Ash.read!()
    |> Enum.filter(&(&1.workspace_id == ws_id and &1.kind == :escalation))
  end

  describe "lifecycle/3 :pr_opened" do
    test "transitions to In Code Review, comments the PR URL, and adds a remote link" do
      test_pid = self()
      ws = jira_workspace(%{"pr_opened" => "In Code Review"})

      issue =
        jira_issue(ws, %{
          qa_notes: "Verify voice ID matches on re-enrollment.",
          deployment_notes: "None."
        })

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "51",
                  "name" => "Pull request created",
                  "to" => %{"name" => "In Code Review"}
                }
              ]
            })

          conn.method == "PUT" and String.ends_with?(path, "/issue/#{@ref}") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:update_fields, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})

          conn.method == "POST" and String.ends_with?(path, "/transitions") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})

          conn.method == "POST" and String.ends_with?(path, "/comment") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:comment, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "1"})

          conn.method == "POST" and String.ends_with?(path, "/remotelink") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:remotelink, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 10_001})
        end
      end)

      url = "https://github.com/leo/voice-id-core/pull/3606"

      assert :ok =
               Sync.lifecycle(issue, :pr_opened, pr_url: url, pr_title: "PR #3606 (#{issue.id})")

      # bd-4isprn: the QA/Deployment notes fields are pushed BEFORE the
      # transition is attempted — LeoTech's Story workflow gates "Pull
      # request created" on them via a workflow validator invisible to the
      # transitions-metadata detection, so they're forced regardless.
      assert_receive {:update_fields,
                      %{
                        "fields" => %{
                          "customfield_10184" => _qa_notes,
                          "customfield_10185" => _deployment_notes
                        }
                      }}

      # Transitioned toward "In Code Review" (single-hop via "Pull request created").
      assert_receive {:transition, %{"transition" => %{"id" => "51"}}}
      # Commented with the PR URL (ADF body).
      assert_receive {:comment, %{"body" => %{"type" => "doc"} = adf}}
      assert adf |> get_in(["content"]) |> is_list()
      # Added a remote link keyed off the PR URL (idempotent globalId).
      assert_receive {:remotelink,
                      %{"object" => %{"url" => ^url}, "globalId" => "arbiter-pr=" <> _}}

      # No spurious escalation on the happy path.
      assert escalations_for(ws.id) == []
    end

    test "escalates and does NOT attempt the transition when QA/Deployment notes are blank (bd-4isprn)" do
      test_pid = self()
      ws = jira_workspace(%{"pr_opened" => "In Code Review"})
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "51",
                  "name" => "Pull request created",
                  "to" => %{"name" => "In Code Review"}
                }
              ]
            })

          # attach_pr_artifacts runs regardless of the gated transition's
          # outcome — assert only that the (doomed) transition/field-update
          # calls never fire, not that nothing else does.
          conn.method == "POST" and String.ends_with?(path, "/comment") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "1"})

          conn.method == "POST" and String.ends_with?(path, "/remotelink") ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 10_001})

          true ->
            send(test_pid, {:unexpected, conn.method, path})
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      url = "https://github.com/leo/voice-id-core/pull/3606"

      assert :ok =
               Sync.lifecycle(issue, :pr_opened, pr_url: url, pr_title: "PR #3606 (#{issue.id})")

      refute_receive {:unexpected, _method, _path}

      assert [escalation] = escalations_for(ws.id)
      assert escalation.body =~ "QA Testing Notes"
      assert escalation.body =~ "Deployment Notes"
    end
  end

  describe "lifecycle/3 :approved_unmerged" do
    test "transitions an approved-but-parked ticket to Pending Merge" do
      test_pid = self()
      ws = jira_workspace(%{"approved_unmerged" => "Pending Merge"})
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        cond do
          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "111",
                  "name" => "Approved and not merged",
                  "to" => %{"name" => "Pending Merge"}
                }
              ]
            })

          conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert :ok = Sync.lifecycle(issue, :approved_unmerged)

      assert_receive {:transition, %{"transition" => %{"id" => "111"}}}
      assert escalations_for(ws.id) == []
    end
  end

  describe "lifecycle/3 :merged" do
    test "transitions a merged ticket to Code Complete" do
      test_pid = self()
      ws = jira_workspace(%{"merged" => "Code Complete"})
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        cond do
          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "222",
                  "name" => "Approved and merged",
                  "to" => %{"name" => "Code Complete"}
                }
              ]
            })

          conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert :ok = Sync.lifecycle(issue, :merged)

      assert_receive {:transition, %{"transition" => %{"id" => "222"}}}
      assert escalations_for(ws.id) == []
    end
  end

  describe "loud failure -> escalation" do
    test "an unreachable mapped status raises an escalation instead of failing silently" do
      # in_progress -> "Nowhere" is unreachable: no direct transition and no
      # graph path. This is exactly the VR-17911 silent-failure shape.
      ws = jira_workspace(%{"in_progress" => "Nowhere"})
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        if conn.method == "GET" and String.ends_with?(conn.request_path, "/transitions") do
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "transitions" => [
              %{"id" => "9", "name" => "noop", "to" => %{"name" => "In Code Review"}}
            ]
          })
        else
          # current-status fetch
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"fields" => %{"status" => %{"name" => "In Progress"}}})
        end
      end)

      # lifecycle/3 seeds the adapter config from the workspace, then drives
      # the transition; the loud failure surfaces as an escalation (the call
      # itself stays best-effort and returns :ok).
      assert :ok = Sync.lifecycle(issue, :in_progress)

      escalations = escalations_for(ws.id)
      assert length(escalations) == 1
      [summons] = escalations
      assert summons.to_ref == "admiral"
      assert summons.directive_ref == issue.id
      assert summons.subject =~ "tracker sync failed"
      assert summons.body =~ "status_map"
    end

    test "a benign unmapped event is skipped without an escalation" do
      # The tracker explicitly does not model :merged (blank mapping overrides
      # the default). map_status -> :status_unmapped, which is a quiet skip.
      ws = jira_workspace(%{"in_progress" => "In Progress", "merged" => ""})
      issue = jira_issue(ws)

      # No HTTP stub needed: map_status short-circuits before any request.
      assert :ok = Sync.transition_event(issue, :merged)
      assert escalations_for(ws.id) == []
    end

    test "an untracked task is a no-op" do
      ws = jira_workspace(%{"in_progress" => "In Progress"})

      {:ok, issue} =
        Ash.create(Issue, %{title: "untracked", tracker_type: :none, workspace_id: ws.id})

      assert :ok = Sync.lifecycle(issue, :pr_opened, pr_url: "https://x/pr/1")
      assert escalations_for(ws.id) == []
    end
  end

  describe "gated transition: push produced fields before transitioning" do
    # The VR-17958 incident: the pr_opened -> "In Code Review" transition is
    # GATED on QA Testing Notes + Deployment Notes. The worker had already
    # produced both on the bead, but arbiter escalated instead of pushing them.
    # The gate is discovered from Jira (`expand=transitions.fields`), so no
    # provider-specific logic lives in this sync layer.

    defp jira_issue_with(ws, attrs) do
      {:ok, issue} =
        Ash.create(
          Issue,
          Map.merge(
            %{
              title: "tracked",
              tracker_type: :jira,
              tracker_ref: @ref,
              skip_upstream_create: true,
              workspace_id: ws.id
            },
            attrs
          )
        )

      issue
    end

    # GET /transitions advertises the gated "Pull request created" transition
    # (required QA + Deployment fields); PUT records the field write; POST
    # records the transition.
    defp gated_pr_opened_stub(test_pid) do
      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "51",
                  "name" => "Pull request created",
                  "to" => %{"name" => "In Code Review"},
                  "fields" => %{
                    "customfield_10184" => %{"required" => true, "name" => "QA Testing Notes"},
                    "customfield_10185" => %{"required" => true, "name" => "Deployment Notes"}
                  }
                }
              ]
            })

          conn.method == "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:put_fields, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})

          conn.method == "POST" and String.ends_with?(path, "/transitions") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})

          conn.method == "POST" ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "1"})
        end
      end)
    end

    test "pushes the produced QA + Deployment notes, THEN transitions" do
      test_pid = self()
      ws = jira_workspace(%{"pr_opened" => "In Code Review"})

      issue =
        jira_issue_with(ws, %{
          qa_notes: "Hit GET /v2/foo with a valid token; expect 200 + the new field.",
          deployment_notes: "No migration. Behind the `foo_v2` flag, default off."
        })

      gated_pr_opened_stub(test_pid)

      assert :ok = Sync.lifecycle(issue, :pr_opened, pr_url: "https://x/pr/1")

      # Fields are written first…
      assert_receive {:put_fields, %{"fields" => fields}}
      assert fields["customfield_10184"]["type"] == "doc"
      assert fields["customfield_10185"]["type"] == "doc"
      # …then the gated transition fires.
      assert_receive {:transition, %{"transition" => %{"id" => "51"}}}
      # No escalation: the gate was satisfied automatically.
      assert escalations_for(ws.id) == []
    end

    test "escalates naming the exact missing field; does NOT transition" do
      test_pid = self()
      ws = jira_workspace(%{"pr_opened" => "In Code Review"})

      # QA Notes produced, Deployment Notes genuinely missing.
      issue = jira_issue_with(ws, %{qa_notes: "Smoke-test the endpoint.", deployment_notes: nil})

      gated_pr_opened_stub(test_pid)

      assert :ok = Sync.lifecycle(issue, :pr_opened, pr_url: "https://x/pr/1")

      # Nothing is written or transitioned — the gate isn't satisfiable.
      refute_receive {:put_fields, _}
      refute_receive {:transition, _}

      # The escalation names the specific missing field, not a generic
      # status_map hint.
      escalations = escalations_for(ws.id)
      assert length(escalations) == 1
      [summons] = escalations
      assert summons.subject =~ "tracker sync failed"
      assert summons.body =~ "Deployment Notes"
      refute summons.body =~ "QA Testing Notes"
      refute summons.body =~ "status_map"
    end
  end

  # ---- Regression: benign already-at-target-state recovery (bd-5hi4u4) ------
  #
  # When a fleet PR merges with `Closes #N`, GitHub auto-closes the issue.
  # Arbiter's bead-close then fires `transition_event(issue, :closed)`, which
  # GETs the issue (finds it open due to a race), attempts a PATCH, and GitHub
  # rejects it with 422 "Validation Failed" because the issue was just closed.
  # The fix: re-fetch after a validation_failed — if the item is already at the
  # desired state, treat the whole transition as a success (no escalation).

  @github_ref "673"
  @github_env "GTE_TRACKER_SYNC_GITHUB_TOKEN"

  defp github_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gh-ws-#{System.unique_integer([:positive])}",
        prefix: "gh",
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{
              "owner" => "ryanrborn",
              "repo" => "arbiter",
              "credentials_ref" => "env:#{@github_env}"
            }
          }
        }
      })

    ws
  end

  defp github_issue(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "tracked",
        tracker_type: :github,
        tracker_ref: @github_ref,
        skip_upstream_create: true,
        workspace_id: ws.id
      })

    issue
  end

  describe "already-at-target-state recovery (bd-5hi4u4)" do
    setup do
      System.put_env(@github_env, "test-github-token")
      on_exit(fn -> System.delete_env(@github_env) end)
      :ok
    end

    test "PATCH→422 followed by already-closed GET: no escalation (Closes #N race)" do
      # Simulates the `Closes #N` race: our GET sees the issue as open (before
      # GitHub processes the keyword), the PATCH is rejected 422 because GitHub
      # auto-closed it, but the recovery GET confirms it is now closed.
      # Expected: no escalation — the desired state was already reached.
      {:ok, call_count} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> catch_exit(Agent.stop(call_count)) end)

      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case conn.method do
          "GET" ->
            n = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)
            # First GET (pre-flight in transition/2): issue appears open.
            # Second GET (recovery in already_at_target?): issue is now closed.
            state = if n == 0, do: "open", else: "closed"

            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 673, "state" => state, "labels" => []})

          "PATCH" ->
            # GitHub rejects: issue was just auto-closed between our GET and PATCH.
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"message" => "Validation Failed", "errors" => []})
        end
      end)

      ws = github_workspace()
      issue = github_issue(ws)

      # lifecycle/3 always returns :ok (best-effort); verify via escalation count.
      assert :ok = Sync.lifecycle(issue, :closed)
      assert escalations_for(ws.id) == []
    end

    test "PATCH→422 with issue still open: escalation fires (genuine failure)" do
      # The PATCH is rejected AND the recovery GET confirms the issue is still
      # open → this is a real sync failure, not a benign race.
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"number" => 673, "state" => "open", "labels" => []})

          "PATCH" ->
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"message" => "Validation Failed", "errors" => []})
        end
      end)

      ws = github_workspace()
      issue = github_issue(ws)

      assert :ok = Sync.lifecycle(issue, :closed)

      escalations = escalations_for(ws.id)
      assert length(escalations) == 1
    end

    test "tracker unreachable (5xx): escalation fires, no spurious no-op" do
      # A server error before even reaching the PATCH is a genuine failure.
      # The already_at_target? recovery only fires for validation_failed, not 5xx,
      # so the escalation must still be raised.
      Req.Test.stub(Arbiter.Trackers.GitHub.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"message" => "Internal Server Error"})
      end)

      ws = github_workspace()
      issue = github_issue(ws)

      assert :ok = Sync.lifecycle(issue, :closed)

      escalations = escalations_for(ws.id)
      assert length(escalations) == 1
    end

    test "jira: POST transition→422 followed by already-Done GET: no escalation" do
      # The Jira analogue of the GitHub race: the close transition POSTs, Jira
      # rejects it (400/422 — the issue is already in a Done status so the
      # transition is invalid), and the recovery GET confirms the issue's
      # statusCategory is already "done". Expected: benign no-op, no escalation.
      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            # A direct transition to Done is advertised (single-hop fast path).
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{"id" => "31", "name" => "Done", "to" => %{"name" => "Done"}}
              ]
            })

          conn.method == "POST" and String.ends_with?(path, "/transitions") ->
            # Jira rejects the redundant transition.
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"errorMessages" => ["Transition is not valid."], "errors" => %{}})

          conn.method == "GET" ->
            # Recovery fetch (already_at_target?): the issue is already Done.
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "key" => @ref,
              "fields" => %{"status" => %{"statusCategory" => %{"key" => "done"}}}
            })
        end
      end)

      ws = jira_workspace(%{"closed" => "Done"})
      issue = jira_issue(ws)

      assert :ok = Sync.lifecycle(issue, :closed)
      assert escalations_for(ws.id) == []
    end
  end

  # ---- Regression: fix version gating (bd-1924hi) ---------------------------
  #
  # LeoTech's Jira VR workflow requires a fix version before certain transitions.
  # Two sub-cases:
  #   A. Jira reports fixVersions as a required field via expand=transitions.fields
  #      → the gating machinery pre-resolves from workspace `fix_version_name` and
  #      pushes it before the transition (no retry needed).
  #   B. Jira does NOT report fixVersions in transitions.fields (workflow validator
  #      gap) → post_transition 400 with "fix version" error message → retry with
  #      fix_version_name from workspace config.
  # In both cases: exactly ONE escalation when the config is absent; zero when set.

  defp jira_workspace_with_fix_version(status_map, fix_version_name) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "jira-fv-ws-#{System.unique_integer([:positive])}",
        prefix: "jfv",
        config: %{
          "tracker" => %{
            "type" => "jira",
            "config" => %{
              "host" => "leotechnologies.atlassian.net",
              "project_key" => "VR",
              "credentials_ref" => "env:#{@env}",
              "email" => "tester@example.com",
              "status_map" => status_map,
              "fix_version_name" => fix_version_name
            }
          }
        }
      })

    ws
  end

  describe "fix version gating via gating_fields (bd-1924hi case A)" do
    # Jira reports fixVersions as required in expand=transitions.fields.

    test "workspace has fix_version_name: sets fix version then transitions, no escalation" do
      test_pid = self()
      ws = jira_workspace_with_fix_version(%{"merged" => "Code Complete"}, "2026-Q3")
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "61",
                  "name" => "Approved and merged",
                  "to" => %{"name" => "Code Complete"},
                  # fixVersions is a required gating field on this transition.
                  "fields" => %{
                    "fixVersions" => %{"required" => true, "name" => "Fix Version"}
                  }
                }
              ]
            })

          conn.method == "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:put_fields, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})

          conn.method == "POST" and String.ends_with?(path, "/transitions") ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:transition, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert :ok = Sync.lifecycle(issue, :merged)

      # Fix version is pushed first…
      assert_receive {:put_fields, %{"fields" => %{"fixVersions" => [%{"name" => "2026-Q3"}]}}}

      # …then the transition fires.
      assert_receive {:transition, %{"transition" => %{"id" => "61"}}}

      # No escalation when the gate is satisfied.
      assert escalations_for(ws.id) == []
    end

    test "workspace has no fix_version_name: escalates once naming Fix Version, no transition" do
      test_pid = self()
      # nil fix_version_name → not configured
      ws = jira_workspace_with_fix_version(%{"merged" => "Code Complete"}, nil)
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        if conn.method == "GET" and String.ends_with?(path, "/transitions") do
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "transitions" => [
              %{
                "id" => "61",
                "name" => "Approved and merged",
                "to" => %{"name" => "Code Complete"},
                "fields" => %{
                  "fixVersions" => %{"required" => true, "name" => "Fix Version"}
                }
              }
            ]
          })
        else
          send(test_pid, {:unexpected_call, conn.method, conn.request_path})
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        end
      end)

      assert :ok = Sync.lifecycle(issue, :merged)

      # No PUT (no fields to push) and no POST (transition skipped).
      refute_receive {:transition, _}

      # Exactly ONE escalation naming the missing field.
      escalations = escalations_for(ws.id)
      assert length(escalations) == 1
      [esc] = escalations
      assert esc.body =~ "Fix Version"
    end
  end

  describe "fix version workflow-validator retry (bd-1924hi case B)" do
    # Jira does NOT report fixVersions in transitions.fields but rejects the
    # transition with "A fix version must be assigned...".

    test "workspace has fix_version_name: sets fix version and retries, no escalation" do
      test_pid = self()
      ws = jira_workspace_with_fix_version(%{"merged" => "Code Complete"}, "2026-Q3")
      issue = jira_issue(ws)

      {:ok, call_count} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> catch_exit(Agent.stop(call_count)) end)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            # No fixVersions in the fields — it's a workflow validator, not screen.
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "61",
                  "name" => "Approved and merged",
                  "to" => %{"name" => "Code Complete"}
                }
              ]
            })

          conn.method == "POST" and String.ends_with?(path, "/transitions") ->
            n = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

            if n == 0 do
              # First attempt: Jira rejects (workflow validator gap).
              conn
              |> Plug.Conn.put_status(400)
              |> Req.Test.json(%{
                "errorMessages" => [
                  "A fix version must be assigned in order to transition the issue from this status."
                ],
                "errors" => %{}
              })
            else
              # Second attempt (after fix version set): succeeds.
              send(test_pid, :transition_retry)
              conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
            end

          conn.method == "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:put_fix_version, Jason.decode!(body)})
            conn |> Plug.Conn.put_status(204) |> Req.Test.json(%{})
        end
      end)

      assert :ok = Sync.lifecycle(issue, :merged)

      # Fix version is pushed between the two transition attempts.
      assert_receive {:put_fix_version,
                      %{"fields" => %{"fixVersions" => [%{"name" => "2026-Q3"}]}}}

      assert escalations_for(ws.id) == []
    end

    test "workspace has no fix_version_name: single escalation (no retry loop)" do
      ws = jira_workspace_with_fix_version(%{"merged" => "Code Complete"}, nil)
      issue = jira_issue(ws)

      Req.Test.stub(Arbiter.Trackers.Jira.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and String.ends_with?(path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "transitions" => [
                %{
                  "id" => "61",
                  "name" => "Approved and merged",
                  "to" => %{"name" => "Code Complete"}
                }
              ]
            })

          conn.method == "POST" and String.ends_with?(path, "/transitions") ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{
              "errorMessages" => [
                "A fix version must be assigned in order to transition the issue from this status."
              ],
              "errors" => %{}
            })

          # Recovery: re-fetch to check if already at target (already_at_target?).
          conn.method == "GET" ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{
              "key" => @ref,
              "fields" => %{"status" => %{"statusCategory" => %{"key" => "new"}}}
            })
        end
      end)

      assert :ok = Sync.lifecycle(issue, :merged)

      # Exactly ONE escalation — not 14.
      assert length(escalations_for(ws.id)) == 1
    end
  end

  describe "escalation deduplication (bd-1924hi)" do
    # A single merge can trigger lifecycle(:merged) from multiple callers
    # (Watchdog, MergeQueue, MergedPRFinalizer). The dedup window ensures only
    # ONE escalation lands per (task, event) per 5-minute window.

    test "calling notify_failure twice for the same task+event raises only one escalation" do
      ws = jira_workspace(%{"merged" => "Code Complete"})
      issue = jira_issue(ws)

      reason = %{
        kind: :validation_failed,
        message: "A fix version must be assigned",
        status: 400,
        raw: nil
      }

      Sync.notify_failure(issue, :merged, reason)
      Sync.notify_failure(issue, :merged, reason)

      # Only the first call fires the Admiral escalation.
      assert length(escalations_for(ws.id)) == 1
    end

    test "calling notify_failure for different events raises separate escalations" do
      ws = jira_workspace(%{"merged" => "Code Complete", "closed" => "Done"})
      issue = jira_issue(ws)

      reason = %{
        kind: :validation_failed,
        message: "A fix version must be assigned",
        status: 400,
        raw: nil
      }

      Sync.notify_failure(issue, :merged, reason)
      Sync.notify_failure(issue, :closed, reason)

      # Different events → two separate escalations are allowed.
      assert length(escalations_for(ws.id)) == 2
    end
  end
end
