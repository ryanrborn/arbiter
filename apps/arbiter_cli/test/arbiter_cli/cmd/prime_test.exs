defmodule ArbiterCli.Cmd.PrimeTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Prime

  defp stub_all(workspaces, polecats, ready, admiral \\ []) do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => workspaces}, 200}},
      {{"get", "/api/polecats"}, {%{"data" => polecats}, 200}},
      {{"get", "/api/issues/ready"}, {%{"data" => ready}, 200}},
      {{"get", "/api/messages"}, {%{"data" => admiral}, 200}}
    ])
  end

  describe "text mode" do
    test "prints all four sections with data populated" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "tracker" => %{"type" => "jira"},
              "vernacular" => %{"worker" => "Acolyte", "issue" => "Directive"}
            }
          }
        ],
        [
          %{
            "bead_id" => "bd-001",
            "status" => "running",
            "current_step" => "implement",
            "rig" => "test/rig"
          }
        ],
        [
          %{"id" => "bd-002", "priority" => 1, "issue_type" => "bug", "title" => "Fix the thing"}
        ]
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Active workspace =="
      assert out =~ "default"
      assert out =~ "tracker: jira"

      assert out =~ "== Vernacular =="
      assert out =~ "worker: Acolyte"

      # Section headers use the active vernacular.
      assert out =~ "== Active Acolytes (1) =="
      assert out =~ "bd-001"
      assert out =~ "step=implement"

      assert out =~ "== Ready Directives (1) =="
      assert out =~ "bd-002"
      assert out =~ "Fix the thing"
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

    test "empty polecats and ready beads render '(none)'" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Active polecats =="
      assert out =~ "(none)"
      assert out =~ "== Ready beads =="
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
                %{"title" => "No merge to main without the Tribunal review gate"}
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
      assert out =~ "[ ] No merge to main without the Tribunal review gate"

      # Surfaced high: before the work list (polecats / ready beads).
      orders_at = :binary.match(out, "== Standing Orders ==") |> elem(0)
      ready_at = :binary.match(out, "== Ready beads ==") |> elem(0)
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

    test "always shows the Operating Pitfalls digest with a pointer to ARBITER_OPERATOR.md" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "== Operating Pitfalls =="
      assert out =~ "[ ] Concurrency:"
      assert out =~ "[ ] Config:"
      assert out =~ "[ ] Deploy:"
      assert out =~ "[ ] Tribunal:"
      assert out =~ "ARBITER_OPERATOR.md"

      # Surfaced above the work list.
      pitfalls_at = :binary.match(out, "== Operating Pitfalls ==") |> elem(0)
      ready_at = :binary.match(out, "== Ready beads ==") |> elem(0)
      assert pitfalls_at < ready_at
    end

    test "Operating Pitfalls digest uses the active vernacular terms" do
      stub_all(
        [
          %{
            "id" => "ws-1",
            "name" => "default",
            "prefix" => "bd",
            "config" => %{
              "vernacular" => %{"worker" => "Acolyte", "issue" => "Directive", "rig" => "Outpost"}
            }
          }
        ],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run([]) end)
      assert exit_code == 0

      assert out =~ "Directive"
      assert out =~ "Acolyte"
      assert out =~ "Outpost"
    end

    test "empty vernacular reports 'default gas-town'" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, _exit} = capture(fn -> Prime.run([]) end)
      assert out =~ "(default gas-town"
    end
  end

  describe "--json mode" do
    test "emits a single JSON object with all sections including field_guide_pitfalls" do
      stub_all(
        [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}],
        [],
        []
      )

      {out, _err, exit_code} = capture(fn -> Prime.run(["--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      assert is_map(decoded)
      assert Map.has_key?(decoded, "workspace")
      assert Map.has_key?(decoded, "polecats")
      assert Map.has_key?(decoded, "ready")
      assert Map.has_key?(decoded, "admiral_inbox")
      assert Map.has_key?(decoded, "standing_orders")
      assert Map.has_key?(decoded, "field_guide_pitfalls")
      assert is_list(decoded["field_guide_pitfalls"])
      assert length(decoded["field_guide_pitfalls"]) > 0
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
      assert decoded["standing_orders"] == ["Watch the Admiral inbox"]
    end
  end
end
