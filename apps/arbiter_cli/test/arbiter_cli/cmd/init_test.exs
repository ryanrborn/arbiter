defmodule ArbiterCli.Cmd.InitTest do
  # async: false — one test changes the process cwd, which is global state.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Init

  # A customised install: gas-town is overridden with admiral-ish terms so we
  # can prove the generated docs follow the active vernacular, not a hardcode.
  defp stub_install(
         vernacular \\ %{
           "coordinator" => "Admiral",
           "worker" => "acolyte",
           "issue" => "directive"
         }
       ) do
    # Named "default" so Workspace.resolve/0 (which targets ARB_WORKSPACE,
    # defaulting to "default") matches it; the custom prefix proves the
    # domain data is templated in rather than hardcoded.
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "emr"}]}, 200}},
      {{"get", "/api/settings"}, {%{"data" => %{"vernacular" => vernacular}}, 200}}
    ])
  end

  defp tmp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "arb_init_test_" <> Integer.to_string(System.unique_integer([:positive]))
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "scaffolding" do
    test "creates all five artifacts pre-filled with the active install" do
      stub_install()
      dir = tmp_dir()

      {out, _err, exit_code} = capture(fn -> Init.run([dir]) end)
      assert exit_code == 0

      assert File.exists?(Path.join(dir, "CLAUDE.md"))
      assert File.exists?(Path.join(dir, "CLAUDE.local.md"))
      assert File.exists?(Path.join(dir, ".gitignore"))
      assert File.exists?(Path.join(dir, "memory/MEMORY.md"))
      assert File.exists?(Path.join(dir, "notes/README.md"))

      assert out =~ "created"
      assert out =~ "CLAUDE.md"
    end

    test "CLAUDE.md uses the active vernacular and the domain name/prefix" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      claude = File.read!(Path.join(dir, "CLAUDE.md"))

      # Coordinator term comes from vernacular, capitalised in the heading.
      assert claude =~ "# Admiral — Arbiter command session"
      assert claude =~ "acolytes"
      assert claude =~ "directive"

      # Domain name + prefix templated from Workspace.resolve/0.
      assert claude =~ "**default** (prefix `emr`)"
      assert claude =~ "emr-001"
      assert claude =~ "emr-1 blocks emr-2"

      # Host templated from ARB_HOST default.
      assert claude =~ "http://127.0.0.1:4848"

      # Tells the agent to read standing orders from `arb prime` (sibling bead).
      assert claude =~ "arb prime"
      assert claude =~ "standing orders"
    end

    test "generated CLAUDE.md carries NO persona" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      claude = File.read!(Path.join(dir, "CLAUDE.md"))

      refute claude =~ "Darth"
      refute claude =~ "Gnosis"
      refute claude =~ "Sith"
      refute claude =~ "Penumbral"
    end

    test "CLAUDE.local.md is a stub overlay with no persona, and .gitignore hides it" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)

      local = File.read!(Path.join(dir, "CLAUDE.local.md"))
      assert local =~ "Personal overlay"
      assert local =~ "gitignored"
      refute local =~ "Darth"

      gitignore = File.read!(Path.join(dir, ".gitignore"))
      assert gitignore =~ "CLAUDE.local.md"
    end

    test "MEMORY.md is a clean skeleton index" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      memory = File.read!(Path.join(dir, "memory/MEMORY.md"))

      assert memory =~ "Admiral Memory"
      assert memory =~ "Add entries below"
    end

    test "defaults the target directory to cwd when no path is given" do
      stub_install()
      dir = tmp_dir()
      File.mkdir_p!(dir)

      File.cd!(dir, fn ->
        {_out, _err, exit_code} = capture(fn -> Init.run([]) end)
        assert exit_code == 0
      end)

      assert File.exists?(Path.join(dir, "CLAUDE.md"))
    end
  end

  describe "non-destructive behavior" do
    test "skips files that already exist and reports them" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)

      # Tamper with an existing file; a plain re-run must not clobber it.
      sentinel = "DO NOT OVERWRITE\n"
      File.write!(Path.join(dir, "CLAUDE.md"), sentinel)

      {out, _err, exit_code} = capture(fn -> Init.run([dir]) end)
      assert exit_code == 0
      assert out =~ "skipped"
      assert File.read!(Path.join(dir, "CLAUDE.md")) == sentinel
    end

    test "--force overwrites existing files" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      File.write!(Path.join(dir, "CLAUDE.md"), "stale\n")

      {out, _err, exit_code} = capture(fn -> Init.run([dir, "--force"]) end)
      assert exit_code == 0
      assert out =~ "overwritten"
      assert File.read!(Path.join(dir, "CLAUDE.md")) =~ "Arbiter command session"
    end
  end

  describe "resilience" do
    test "scaffolds with gas-town defaults when the server is unreachable" do
      stub_transport_error(:get, "/api/settings", :econnrefused)
      dir = tmp_dir()

      {_out, _err, exit_code} = capture(fn -> Init.run([dir]) end)
      assert exit_code == 0

      claude = File.read!(Path.join(dir, "CLAUDE.md"))
      # Falls back to the CLI default vernacular and domain.
      assert claude =~ "polecat"
      assert claude =~ "bd-001"
    end
  end

  describe "--json mode" do
    test "emits a machine-readable summary" do
      stub_install()
      dir = tmp_dir()

      {out, _err, exit_code} = capture(fn -> Init.run([dir, "--json"]) end)
      assert exit_code == 0

      {:ok, decoded} = Jason.decode(String.trim(out))
      assert decoded["dir"] == dir
      assert decoded["vernacular"]["coordinator"] == "Admiral"
      assert decoded["domain"]["prefix"] == "emr"
      assert is_list(decoded["files"])
      assert Enum.any?(decoded["files"], fn f -> f["path"] == "CLAUDE.md" end)
    end
  end
end
