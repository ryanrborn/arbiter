defmodule ArbiterCli.Cmd.ConfigTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Config

  @ws_id "ws-1"

  defp default_ws(config) do
    %{"data" => [%{"name" => "default", "id" => @ws_id, "prefix" => "bd", "config" => config}]}
  end

  describe "pure helpers" do
    test "parse_value/1 covers true/false/int/json/string" do
      assert Config.parse_value("true") == true
      assert Config.parse_value("false") == false
      assert Config.parse_value("42") == 42
      assert Config.parse_value("-7") == -7
      assert Config.parse_value(~s({"a":1})) == %{"a" => 1}
      assert Config.parse_value("[1,2,3]") == [1, 2, 3]
      assert Config.parse_value("null") == nil
      assert Config.parse_value("hello") == "hello"
      # Garbage JSON falls back to the raw string.
      assert Config.parse_value("{not json}") == "{not json}"
    end

    test "split/1 drops empty segments" do
      assert Config.split("a.b.c") == ["a", "b", "c"]
      assert Config.split(".a..b") == ["a", "b"]
    end

    test "put_in_path/3 + get_in_path/2 build and read nested maps" do
      m = Config.put_in_path(%{"x" => 1}, ["a", "b", "c"], true)
      assert Config.get_in_path(m, ["a", "b", "c"]) == true
      assert Config.get_in_path(m, ["x"]) == 1
      assert Config.get_in_path(m, ["nope"]) == nil
    end

    test "deep_merge/2 preserves siblings and recurses into maps" do
      assert Config.deep_merge(
               %{"a" => %{"x" => 1}, "b" => 2},
               %{"a" => %{"y" => 9}, "c" => 3}
             ) == %{"a" => %{"x" => 1, "y" => 9}, "b" => 2, "c" => 3}
    end

    test "drop_path/2 removes a leaf, no-op for missing paths" do
      m = %{"a" => %{"b" => 1, "c" => 2}}
      assert Config.drop_path(m, ["a", "b"]) == %{"a" => %{"c" => 2}}
      assert Config.drop_path(m, ["a", "nope"]) == m
      assert Config.drop_path(m, ["nope", "x"]) == m
    end

    test "safety_check/1 flags empty rig_paths" do
      assert {:unsafe, [reason]} = Config.safety_check(%{"rig_paths" => %{}})
      assert reason =~ "rig_paths is empty"
    end

    test "safety_check/1 flags tracker.type != none without tracker.config" do
      assert {:unsafe, [reason]} = Config.safety_check(%{"tracker" => %{"type" => "github"}})
      assert reason =~ "tracker.type is \"github\""
    end

    test "safety_check/1 accepts github merge with no owner or repo (both per-rig derivable)" do
      assert :ok =
               Config.safety_check(%{"merge" => %{"strategy" => "github"}})
    end

    test "safety_check/1 accepts a fully populated config" do
      assert :ok =
               Config.safety_check(%{
                 "tracker" => %{"type" => "github", "config" => %{"owner" => "x"}},
                 "merge" => %{
                   "strategy" => "github",
                   "config" => %{"owner" => "x"}
                 }
               })
    end

    test "safety_check/1 accepts a none-tracker without a config block" do
      assert :ok = Config.safety_check(%{"tracker" => %{"type" => "none"}})
    end
  end

  describe "get" do
    test "prints the full config when no key is given" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{"merge" => %{"auto_merge" => true}}), 200}}
      ])

      {out, _err, code} = capture(fn -> Config.run(["get"]) end)
      assert code == 0
      assert out =~ "\"auto_merge\""
      assert out =~ "true"
    end

    test "prints a single dotted leaf with --json" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{"tracker" => %{"type" => "github"}}), 200}}
      ])

      {out, _err, code} = capture(fn -> Config.run(["get", "tracker.type", "--json"]) end)
      assert code == 0
      assert String.trim(out) == ~s("github")
    end

    test "errors on a missing key (text mode)" do
      stub_routes([{{"get", "/api/workspaces"}, {default_ws(%{}), 200}}])

      {_out, err, code} = capture(fn -> Config.run(["get", "nope.here"]) end)
      assert code == 1
      assert err =~ "key not found"
    end
  end

  describe "set" do
    test "sends a deep-merge patch built from the dotted key" do
      initial = %{
        "merge" => %{
          "strategy" => "github",
          "config" => %{"owner" => "leo", "repo" => "arbiter"}
        }
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(initial), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["patch"] == %{"merge" => %{"auto_merge" => true}}

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "id" => @ws_id,
             "name" => "default",
             "config" => Map.put(initial, "merge", Map.put(initial["merge"], "auto_merge", true))
           })
         end}
      ])

      {out, _err, code} = capture(fn -> Config.run(["set", "merge.auto_merge", "true"]) end)
      assert code == 0
      assert out =~ "updated workspace default"
    end

    test "parses int and json values" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["patch"] == %{"review" => %{"rounds" => 5}}

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => %{}})
         end}
      ])

      {_out, _err, code} = capture(fn -> Config.run(["set", "review.rounds", "5"]) end)
      assert code == 0
    end

    test "refuses (without --force) when the resulting config drops a required key" do
      # rig_paths starts with one entry; setting the only entry to a different
      # key isn't a drop, so we test the bare-empty case by setting an
      # unrelated key on a config that already has empty rig_paths is bogus.
      # Cleanest test: existing has tracker.type=github + config; user clobbers
      # tracker.config — actually, set creates/overwrites a leaf, not removes,
      # so we instead trigger the *type-without-config* path by setting type
      # before there's a config block.
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}}
      ])

      {_out, err, code} = capture(fn -> Config.run(["set", "tracker.type", "github"]) end)
      assert code == 1
      assert err =~ "refusing"
      assert err =~ "tracker.config is missing"
    end

    test "--force overrides a guardrail (and warns)" do
      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(%{}), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         {%{
            "id" => @ws_id,
            "name" => "default",
            "config" => %{"tracker" => %{"type" => "github"}}
          }, 200}}
      ])

      {_out, err, code} =
        capture(fn -> Config.run(["set", "tracker.type", "github", "--force"]) end)

      assert code == 0
      assert err =~ "WARNING"
    end

    test "destructive overwrite of a non-empty leaf needs --force" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {default_ws(%{"tracker" => %{"type" => "github", "config" => %{"owner" => "old"}}}), 200}}
      ])

      {_out, err, code} =
        capture(fn -> Config.run(["set", "tracker.config.owner", "new"]) end)

      assert code == 1
      assert err =~ "before:"
      assert err =~ "after:"
      assert err =~ "--force"
    end
  end

  describe "unset" do
    test "removes a dotted leaf, server-side via unset_paths" do
      initial = %{
        "tracker" => %{"type" => "jira", "config" => %{"host" => "h", "project_key" => "VR"}}
      }

      stub_routes([
        {{"get", "/api/workspaces"}, {default_ws(initial), 200}},
        {{"patch", "/api/workspaces/" <> @ws_id <> "/config"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           decoded = Jason.decode!(body)
           assert decoded["unset_paths"] == ["tracker.config.host"]

           updated = %{
             "tracker" => %{"type" => "jira", "config" => %{"project_key" => "VR"}}
           }

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"id" => @ws_id, "name" => "default", "config" => updated})
         end}
      ])

      # Use --force because removing a leaf is destructive.
      {_out, _err, code} =
        capture(fn -> Config.run(["unset", "tracker.config.host", "--force"]) end)

      assert code == 0
    end

    test "errors when the key doesn't exist" do
      stub_routes([{{"get", "/api/workspaces"}, {default_ws(%{}), 200}}])

      {_out, err, code} = capture(fn -> Config.run(["unset", "no.such.key"]) end)
      assert code == 1
      assert err =~ "key not found"
    end

    test "refuses an unset that empties rig_paths without --force" do
      initial = %{"rig_paths" => %{"arbiter" => "/srv/arbiter"}}
      stub_routes([{{"get", "/api/workspaces"}, {default_ws(initial), 200}}])

      {_out, err, code} = capture(fn -> Config.run(["unset", "rig_paths.arbiter"]) end)
      assert code == 1
      assert err =~ "rig_paths is empty"
    end
  end

  describe "errors" do
    test "no subcommand" do
      {_out, err, code} = capture(fn -> Config.run([]) end)
      assert code == 1
      assert err =~ "requires a subcommand"
    end

    test "unknown subcommand" do
      {_out, err, code} = capture(fn -> Config.run(["frobnicate"]) end)
      assert code == 1
      assert err =~ "unknown config subcommand"
    end

    test "set without value" do
      {_out, err, code} = capture(fn -> Config.run(["set", "x"]) end)
      assert code == 1
      assert err =~ "requires a value"
    end
  end

  describe "--workspace override" do
    test "set targets the named workspace, not the default" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"name" => "default", "id" => "ws-default", "config" => %{}},
              %{"name" => "other", "id" => "ws-other", "config" => %{}}
            ]
          }, 200}},
        {{"patch", "/api/workspaces/ws-other/config"},
         {%{"id" => "ws-other", "name" => "other", "config" => %{}}, 200}}
      ])

      {_out, _err, code} =
        capture(fn ->
          Config.run(["set", "review.rounds", "3", "--workspace", "other"])
        end)

      assert code == 0
    end
  end
end
