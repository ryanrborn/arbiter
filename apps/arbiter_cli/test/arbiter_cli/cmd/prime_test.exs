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

      assert out =~ "== Active polecats (1) =="
      assert out =~ "bd-001"
      assert out =~ "step=implement"

      assert out =~ "== Ready beads (1) =="
      assert out =~ "bd-002"
      assert out =~ "Fix the thing"
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
    test "emits a single JSON object with the four sections" do
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
    end
  end
end
