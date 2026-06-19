defmodule ArbiterCli.Cmd.InitTest do
  # async: false — one test changes the process cwd, which is global state.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Init

  # The generated docs use the plain code terms directly (coordinator, worker,
  # issue, repo). The custom domain prefix proves the domain data is templated
  # in rather than hardcoded.
  defp stub_install do
    # Named "default" so Workspace.resolve/0 (which targets ARB_WORKSPACE,
    # defaulting to "default") matches it.
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "emr"}]}, 200}}
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
    test "creates all six artifacts pre-filled with the active install" do
      stub_install()
      dir = tmp_dir()

      {out, _err, exit_code} = capture(fn -> Init.run([dir]) end)
      assert exit_code == 0

      assert File.exists?(Path.join(dir, "AGENTS.md"))
      assert File.exists?(Path.join(dir, "ARBITER_OPERATOR.md"))
      assert File.exists?(Path.join(dir, "AGENTS.local.md"))
      assert File.exists?(Path.join(dir, ".gitignore"))
      assert File.exists?(Path.join(dir, "memory/MEMORY.md"))
      assert File.exists?(Path.join(dir, "notes/README.md"))

      assert out =~ "created"
      assert out =~ "AGENTS.md"
      assert out =~ "ARBITER_OPERATOR.md"
    end

    test "ARBITER_OPERATOR.md is the operator field guide with all key sections" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      guide = File.read!(Path.join(dir, "ARBITER_OPERATOR.md"))

      # Rendered with the plain code terms.
      assert guide =~ "Coordinator Operator Field Guide"
      assert guide =~ "workers"
      assert guide =~ "issue"

      # Covers the required sections.
      assert guide =~ "Role & Loop"
      assert guide =~ "Concurrency Discipline"
      assert guide =~ "Config Safety"
      assert guide =~ "Deploy Safely"
      assert guide =~ "Trust State, But Verify"
      assert guide =~ "Tribunal"
      assert guide =~ "Provider-Agnostic"

      # Generic — no operator-personal content.
      refute guide =~ "ryan"
      refute guide =~ "Ryan"
    end

    test "ARBITER_OPERATOR.md uses the plain code terms and domain prefix" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      guide = File.read!(Path.join(dir, "ARBITER_OPERATOR.md"))

      assert guide =~ "Coordinator"
      assert guide =~ "worker"
      assert guide =~ "issue"
    end

    test "AGENTS.md uses the plain code terms and the domain name/prefix" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      agents = File.read!(Path.join(dir, "AGENTS.md"))

      # Plain coordinator term, capitalised in the heading.
      assert agents =~ "# Coordinator — Arbiter command session"
      assert agents =~ "workers"
      assert agents =~ "issue"

      # Domain name + prefix templated from Workspace.resolve/0.
      assert agents =~ "**default** (prefix `emr`)"
      assert agents =~ "emr-001"
      assert agents =~ "emr-1 blocks emr-2"

      # Host templated from ARB_HOST default.
      assert agents =~ "http://127.0.0.1:4848"

      # Tells the agent to read standing orders from `arb prime` (sibling bead).
      assert agents =~ "arb prime"
      assert agents =~ "standing orders"
    end

    test "generated AGENTS.md carries NO persona" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      agents = File.read!(Path.join(dir, "AGENTS.md"))

      refute agents =~ "Darth"
      refute agents =~ "Gnosis"
      refute agents =~ "Sith"
      refute agents =~ "Penumbral"
    end

    test "AGENTS.local.md is a stub overlay with no persona, and .gitignore hides it" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)

      local = File.read!(Path.join(dir, "AGENTS.local.md"))
      assert local =~ "Personal overlay"
      assert local =~ "gitignored"
      refute local =~ "Darth"

      gitignore = File.read!(Path.join(dir, ".gitignore"))
      assert gitignore =~ "AGENTS.local.md"
    end

    test "MEMORY.md is a clean skeleton index" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      memory = File.read!(Path.join(dir, "memory/MEMORY.md"))

      assert memory =~ "Coordinator Memory"
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

      assert File.exists?(Path.join(dir, "AGENTS.md"))
    end
  end

  describe "non-destructive behavior" do
    test "skips files that already exist and reports them" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)

      # Tamper with an existing file; a plain re-run must not clobber it.
      sentinel = "DO NOT OVERWRITE\n"
      File.write!(Path.join(dir, "AGENTS.md"), sentinel)

      {out, _err, exit_code} = capture(fn -> Init.run([dir]) end)
      assert exit_code == 0
      assert out =~ "skipped"
      assert File.read!(Path.join(dir, "AGENTS.md")) == sentinel
    end

    test "--force overwrites existing files" do
      stub_install()
      dir = tmp_dir()

      capture(fn -> Init.run([dir]) end)
      File.write!(Path.join(dir, "AGENTS.md"), "stale\n")

      {out, _err, exit_code} = capture(fn -> Init.run([dir, "--force"]) end)
      assert exit_code == 0
      assert out =~ "overwritten"
      assert File.read!(Path.join(dir, "AGENTS.md")) =~ "Arbiter command session"
    end
  end

  describe "resilience" do
    test "scaffolds with the default domain when the server is unreachable" do
      stub_transport_error(:get, "/api/workspaces", :econnrefused)
      dir = tmp_dir()

      {_out, _err, exit_code} = capture(fn -> Init.run([dir]) end)
      assert exit_code == 0

      agents = File.read!(Path.join(dir, "AGENTS.md"))
      # Plain code terms, with the fallback default domain prefix.
      assert agents =~ "worker"
      assert agents =~ "bd-001"
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
      assert decoded["terms"]["coordinator"] == "coordinator"
      assert decoded["domain"]["prefix"] == "emr"
      assert is_list(decoded["files"])
      assert Enum.any?(decoded["files"], fn f -> f["path"] == "AGENTS.md" end)
    end
  end
end
