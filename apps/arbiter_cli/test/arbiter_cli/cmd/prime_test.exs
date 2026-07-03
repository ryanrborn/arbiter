defmodule ArbiterCli.Cmd.PrimeTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Prime

  # All /api/messages requests (admiral + per-workspace coordinator) share
  # a single stub matched by path; query params are not matched by stub_routes.
  defp stub_all(workspaces, workers, ready, messages \\ []) do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => workspaces}, 200}},
      {{"get", "/api/workers"}, {%{"data" => workers}, 200}},
      {{"get", "/api/issues/ready"}, {%{"data" => ready}, 200}},
      {{"get", "/api/messages"}, {%{"data" => messages}, 200}}
    ])
  end

  describe "text mode" do
    test "prints workspace header, workers, and ready tasks" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "tracker" => %{"type" => "jira"}
            }
          }
        ],
        [
          %{
            "task_id" => "bd-001",
            "status" => "running",
            "current_step" => "implement",
            "repo" => "test/repo"
          }
        ],
        [
          %{"id" => "bd-002", "priority" => 1, "issue_type" => "bug", "title" => "Fix the thing"}
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Workspace: default (bd) =="
      assert out =~ "default"
      assert out =~ "tracker: jira"

      assert out =~ "== Active workers (1) =="
      assert out =~ "bd-001"
      assert out =~ "step=implement"

      assert out =~ "== Ready issues (1) =="
      assert out =~ "bd-002"
      assert out =~ "Fix the thing"
    end

    test "lists all workspaces when multiple are configured" do
      stub_all(
        [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}},
          %{"id" => "ws-2", "name" => "leotech", "prefix" => "lt", "config" => %{}}
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Workspace: default (bd) =="
      assert out =~ "== Workspace: leotech (lt) =="

      default_at = :binary.match(out, "== Workspace: default (bd) ==") |> elem(0)
      leotech_at = :binary.match(out, "== Workspace: leotech (lt) ==") |> elem(0)
      assert default_at < leotech_at
    end

    test "renders the security posture section when the workspace carries one" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{},
            "security_posture" => %{
              "mode" => "bypass",
              "allow" => [],
              "deny" => ["Bash(docker:*)"],
              "safe_defaults" => ["no_destructive_fs", "no_force_push"],
              "sandbox" => %{"enabled" => true, "filesystem" => "worktree", "network" => false}
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "security:"
      assert out =~ "mode:    bypass"
      assert out =~ "net=tools-off"
      assert out =~ "2 safe-default + 1 custom"
    end

    test "empty workers and ready tasks render '(none)'" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Active workers =="
      assert out =~ "(none)"
      assert out =~ "== Ready issues =="
    end

    test "renders the Admiral Inbox section when there is unread mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        [
          %{
            "id" => "m-1",
            "kind" => "failure",
            "directive_ref" => "bd-9bn4n9",
            "subject" => "Acolyte exited with code 1",
            "body" => "stderr tail...",
            "inserted_at" => "2026-05-28T11:55:00.000000Z"
          },
          %{
            "id" => "m-2",
            "kind" => "completion",
            "directive_ref" => "bd-6c6w82",
            "subject" => "GitHub adapter complete",
            "body" => "done",
            "inserted_at" => "2026-05-28T11:48:00.000000Z"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      assert out =~ "== Admiral Inbox (2 unread) =="
      assert out =~ "[bd-9bn4n9] failure"
      assert out =~ "Acolyte exited with code 1"
      assert out =~ "[bd-6c6w82] completion"
    end

    test "Admiral Inbox appears before workspace blocks" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        [
          %{
            "id" => "m-1",
            "kind" => "failure",
            "directive_ref" => "bd-9bn4n9",
            "subject" => "Acolyte exited with code 1",
            "inserted_at" => "2026-05-28T11:55:00.000000Z"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      inbox_at = :binary.match(out, "== Admiral Inbox") |> elem(0)
      workspace_at = :binary.match(out, "== Workspace:") |> elem(0)
      assert inbox_at < workspace_at
    end

    test "omits the Admiral Inbox section entirely when there is no unread mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Admiral Inbox"
    end

    test "renders the Coordinator Inbox section when there is unread coordinator mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        [
          %{
            "id" => "m-3",
            "kind" => "escalation",
            "directive_ref" => "bd-abc",
            "subject" => "Worker needs direction",
            "body" => "please advise",
            "inserted_at" => "2026-05-28T12:00:00.000000Z"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      assert out =~ "== Coordinator Inbox"
      assert out =~ "[bd-abc] escalation"
      assert out =~ "Worker needs direction"
    end

    test "omits the Coordinator Inbox section when there is no unread coordinator mail" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Coordinator Inbox"
    end

    test "renders the Standing Orders section from config.standing_orders" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "standing_orders" => [
                "Watch the Admiral inbox — stand a ~60s background poll.",
                %{
                  "title" => "Never boot a second Arbiter instance",
                  "detail" => "it sweeps live runs"
                },
                %{"title" => "No merge to main without the ReviewGate review gate"}
              ]
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Standing Orders =="
      assert out =~ "[ ] Watch the Admiral inbox — stand a ~60s background poll."
      assert out =~ "[ ] Never boot a second Arbiter instance — it sweeps live runs"
      assert out =~ "[ ] No merge to main without the ReviewGate review gate"

      # Surfaced within the workspace block, before the work list.
      orders_at = :binary.match(out, "== Standing Orders ==") |> elem(0)
      ready_at = :binary.match(out, "== Ready issues ==") |> elem(0)
      assert orders_at < ready_at
    end

    test "omits the Standing Orders section entirely when config has none" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Standing Orders"
    end

    test "never shows an Operating Pitfalls section" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0
      refute out =~ "Operating Pitfalls"
    end
  end

  describe "--json mode" do
    test "emits a JSON object with admiral_inbox and workspaces array" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      assert is_map(decoded)
      assert Map.has_key?(decoded, "admiral_inbox")
      assert Map.has_key?(decoded, "workspaces")
      assert is_list(decoded["workspaces"])
      refute Map.has_key?(decoded, "field_guide_pitfalls")

      [ws] = decoded["workspaces"]
      assert Map.has_key?(ws, "workspace")
      assert Map.has_key?(ws, "workers")
      assert Map.has_key?(ws, "ready")
      assert Map.has_key?(ws, "standing_orders")
      assert Map.has_key?(ws, "coordinator_inbox")
    end

    test "workers and coordinator inbox are scoped to their own workspace" do
      # Both stubs return a mixed payload; client-side filtering must assign
      # each worker/message to only the workspace whose id matches.
      stub_all(
        [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}},
          %{"id" => "ws-2", "name" => "leotech", "prefix" => "lt", "config" => %{}}
        ],
        [
          %{
            "task_id" => "bd-001",
            "workspace_id" => "ws-1",
            "status" => "running",
            "current_step" => "implement",
            "repo" => "test/repo"
          },
          %{
            "task_id" => "lt-001",
            "workspace_id" => "ws-2",
            "status" => "running",
            "current_step" => "implement",
            "repo" => "other/repo"
          }
        ],
        [],
        [
          %{
            "id" => "m-ws1",
            "workspace_id" => "ws-1",
            "kind" => "escalation",
            "directive_ref" => "bd-001",
            "subject" => "default coordinator msg",
            "inserted_at" => "2026-05-28T12:00:00.000000Z"
          },
          %{
            "id" => "m-ws2",
            "workspace_id" => "ws-2",
            "kind" => "escalation",
            "directive_ref" => "lt-001",
            "subject" => "leotech coordinator msg",
            "inserted_at" => "2026-05-28T12:00:00.000000Z"
          }
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      [default_ws, leotech_ws] = decoded["workspaces"]

      assert Enum.map(default_ws["workers"], & &1["task_id"]) == ["bd-001"]
      assert Enum.map(leotech_ws["workers"], & &1["task_id"]) == ["lt-001"]

      assert length(default_ws["coordinator_inbox"]) == 1
      assert hd(default_ws["coordinator_inbox"])["id"] == "m-ws1"
      assert length(leotech_ws["coordinator_inbox"]) == 1
      assert hd(leotech_ws["coordinator_inbox"])["id"] == "m-ws2"
    end

    test "workspaces array has one entry per configured workspace" do
      stub_all(
        [
          %{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}},
          %{"id" => "ws-2", "name" => "leotech", "prefix" => "lt", "config" => %{}}
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      assert length(decoded["workspaces"]) == 2

      names = Enum.map(decoded["workspaces"], fn ws -> ws["workspace"]["name"] end)
      assert "default" in names
      assert "leotech" in names
    end

    test "standing_orders carries the config list through --json" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{"standing_orders" => ["Watch the Admiral inbox"]}
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      [ws] = decoded["workspaces"]
      assert ws["standing_orders"] == ["Watch the Admiral inbox"]
    end
  end
end
