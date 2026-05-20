defmodule GtElixirCli.Cmd.PrimeTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Prime

  defp stub_all(workspaces, polecats, ready) do
    stub_routes([
      {{"get", "/api/workspaces"}, {%{"data" => workspaces}, 200}},
      {{"get", "/api/polecats"}, {%{"data" => polecats}, 200}},
      {{"get", "/api/issues/ready"}, {%{"data" => ready}, 200}}
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
    end
  end
end
