defmodule ArbiterCli.Cmd.ListTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.List

  test "prints one line per issue" do
    stub_get("/api/issues", %{
      "data" => [
        %{"id" => "a", "status" => "open", "priority" => 2, "title" => "first"},
        %{"id" => "b", "status" => "closed", "priority" => 1, "title" => "second"}
      ]
    })

    {out, _err, exit_code} = capture(fn -> List.run([]) end)
    assert exit_code == 0
    assert out =~ "first"
    assert out =~ "second"
    assert out =~ "[open]"
    assert out =~ "[closed]"
  end

  test "empty list prints placeholder" do
    stub_get("/api/issues", %{"data" => []})
    {out, _err, exit_code} = capture(fn -> List.run([]) end)
    assert exit_code == 0
    assert out =~ "(no issues)"
  end

  test "--json emits {\"data\": [...]}" do
    stub_get("/api/issues", %{"data" => [%{"id" => "a", "status" => "open"}]})
    {out, _err, exit_code} = capture(fn -> List.run(["--json"]) end)
    assert exit_code == 0
    assert {:ok, %{"data" => [_]}} = Jason.decode(String.trim(out))
  end

  describe "--tracker" do
    @workspace_lookup {{"get", "/api/workspaces"},
                       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]},
                        200}}

    test "merges local beads with unclaimed tracker issues, dedups by tracker_ref" do
      stub_routes([
        {{"get", "/api/issues"},
         {%{
            "data" => [
              %{
                "id" => "bd-claimed",
                "status" => "in_progress",
                "priority" => 2,
                "title" => "Already a bead",
                "tracker_type" => "github",
                "tracker_ref" => "42"
              }
            ]
          }, 200}},
        @workspace_lookup,
        {{"get", "/api/workspaces/ws-1/tracker/issues"},
         {%{
            "supported" => true,
            "data" => [
              %{"ref" => "42", "title" => "Already a bead", "status" => "open"},
              %{
                "ref" => "99",
                "title" => "Unclaimed tracker issue",
                "status" => "open"
              }
            ]
          }, 200}}
      ])

      {out, _err, code} = capture(fn -> List.run(["--tracker"]) end)
      assert code == 0
      # Bead row shown.
      assert out =~ "bd-claimed"
      assert out =~ "Already a bead"
      # Unclaimed row shown with the marker.
      assert out =~ "(unclaimed)"
      assert out =~ "#99"
      assert out =~ "Unclaimed tracker issue"
      # The tracker issue that shares ref=42 with a bead is NOT duplicated as
      # an unclaimed row (it's already represented by the bead). The bead row
      # comes first, the unclaimed row comes after.
      bead_index = :binary.match(out, "Already a bead") |> elem(0)
      unclaimed_index = :binary.match(out, "Unclaimed tracker issue") |> elem(0)
      assert bead_index < unclaimed_index
      # No row with `#42` (that would mean the deduped ref leaked through as
      # an unclaimed row).
      refute out =~ "#42"
    end

    test "degrades cleanly when tracker is :none — emits a stderr notice and shows local beads" do
      stub_routes([
        {{"get", "/api/issues"},
         {%{
            "data" => [
              %{
                "id" => "bd-local",
                "status" => "open",
                "priority" => 1,
                "title" => "Local-only"
              }
            ]
          }, 200}},
        @workspace_lookup,
        {{"get", "/api/workspaces/ws-1/tracker/issues"},
         {%{"supported" => false, "data" => []}, 200}}
      ])

      {out, err, code} = capture(fn -> List.run(["--tracker"]) end)
      assert code == 0
      assert out =~ "bd-local"
      assert err =~ "doesn't support listing"
    end

    test "--tracker --json includes both beads and tracker_issues" do
      stub_routes([
        {{"get", "/api/issues"},
         {%{
            "data" => [
              %{
                "id" => "bd-1",
                "status" => "open",
                "title" => "Local",
                "tracker_type" => "github",
                "tracker_ref" => "1"
              }
            ]
          }, 200}},
        @workspace_lookup,
        {{"get", "/api/workspaces/ws-1/tracker/issues"},
         {%{
            "supported" => true,
            "data" => [
              %{"ref" => "1", "title" => "Local", "status" => "open"},
              %{"ref" => "2", "title" => "Upstream", "status" => "open"}
            ]
          }, 200}}
      ])

      {out, _err, code} = capture(fn -> List.run(["--tracker", "--json"]) end)
      assert code == 0
      assert {:ok, decoded} = Jason.decode(String.trim(out))
      assert length(decoded["data"]) == 1
      assert length(decoded["tracker_issues"]) == 1
      assert Enum.at(decoded["tracker_issues"], 0)["ref"] == "2"
      assert Enum.at(decoded["tracker_issues"], 0)["unclaimed"] == true
    end

    test "without --tracker flag, behaves exactly as today (no tracker call)" do
      stub_get("/api/issues", %{
        "data" => [%{"id" => "a", "status" => "open", "title" => "x"}]
      })

      {out, _err, code} = capture(fn -> List.run([]) end)
      assert code == 0
      assert out =~ "x"
      refute out =~ "(unclaimed)"
    end
  end
end
