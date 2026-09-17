defmodule Arbiter.MCP.AgentConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.AgentConfig
  alias Arbiter.MCP.AgentConfig.Claude
  alias Arbiter.MCP.AgentConfig.Codex
  alias Arbiter.MCP.AgentConfig.Gemini
  alias Arbiter.MCP.Scope

  describe "Claude.config_map/1" do
    test "produces the Claude Code remote-HTTP server shape" do
      config =
        Claude.config_map(mcp_url: "http://127.0.0.1:4848/mcp", scope_token: "tok-123")

      assert %{
               "mcpServers" => %{
                 "arbiter" => %{
                   "type" => "http",
                   "url" => "http://127.0.0.1:4848/mcp",
                   "headers" => %{"Authorization" => "Bearer tok-123"}
                 }
               }
             } = config
    end

    test "honours a custom server_name" do
      config = Claude.config_map(mcp_url: "u", scope_token: "t", server_name: "fleet")
      assert Map.has_key?(config["mcpServers"], "fleet")
    end
  end

  describe "Gemini.config_map/1" do
    test "produces the Gemini CLI remote-HTTP server shape" do
      config =
        Gemini.config_map(mcp_url: "http://127.0.0.1:4848/mcp", scope_token: "tok-g1")

      assert %{
               "mcpServers" => %{
                 "arbiter" => %{
                   "httpUrl" => "http://127.0.0.1:4848/mcp",
                   "headers" => %{"Authorization" => "Bearer tok-g1"}
                 }
               }
             } = config
    end

    test "includes the worker-tier includeTools allowlist by default" do
      config = Gemini.config_map(mcp_url: "u", scope_token: "t")
      tools = config["mcpServers"]["arbiter"]["includeTools"]

      assert is_list(tools)
      assert "task_show" in tools
      assert "task_update_progress" in tools
      assert "inbox_check" in tools
      assert "message_send" in tools
      assert "workspace_show" in tools
    end

    test "omits includeTools when include_tools: nil (coordinator scope)" do
      config = Gemini.config_map(mcp_url: "u", scope_token: "t", include_tools: nil)
      refute Map.has_key?(config["mcpServers"]["arbiter"], "includeTools")
    end

    test "accepts a custom include_tools list" do
      config =
        Gemini.config_map(mcp_url: "u", scope_token: "t", include_tools: ["task_show"])

      assert config["mcpServers"]["arbiter"]["includeTools"] == ["task_show"]
    end

    test "honours a custom server_name" do
      config = Gemini.config_map(mcp_url: "u", scope_token: "t", server_name: "fleet")
      assert Map.has_key?(config["mcpServers"], "fleet")
    end
  end

  describe "Codex.config_toml/1" do
    test "produces a valid TOML with mcp_servers section" do
      toml = Codex.config_toml(mcp_url: "http://127.0.0.1:4848/mcp", scope_token: "tok-c1")

      assert toml =~ "[mcp_servers.arbiter]"
      assert toml =~ ~s(url = "http://127.0.0.1:4848/mcp")
      assert toml =~ "[mcp_servers.arbiter.headers]"
      assert toml =~ ~s(Authorization = "Bearer tok-c1")
    end

    test "honours a custom server_name" do
      toml = Codex.config_toml(mcp_url: "u", scope_token: "t", server_name: "fleet")
      assert toml =~ "[mcp_servers.fleet]"
      assert toml =~ "[mcp_servers.fleet.headers]"
    end
  end

  # bd-m8geh4: `.gemini/settings.json` is the UPSTREAM `gemini` CLI's config
  # file. The `agy` (Antigravity) CLI never reads it, and never reads any
  # worktree-local path at all — see `Arbiter.MCP.AgentConfig.Gemini`'s moduledoc
  # for the live probe that established this.
  describe "Gemini adapter CLI-flavour split (bd-m8geh4)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mcp-agycfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "`.gemini/settings.json` serves the upstream `gemini` CLI only", %{dir: dir} do
      assert :ok =
               Gemini.write_mcp_config(dir, mcp_url: "u", scope_token: "t", cli: :gemini)

      assert File.exists?(Path.join([dir, ".gemini", "settings.json"]))
    end

    test "the `agy` CLI is refused explicitly — never a silent no-op", %{dir: dir} do
      assert {:error, :unsupported} =
               Gemini.write_mcp_config(dir, mcp_url: "u", scope_token: "t", cli: :agy)

      refute File.exists?(Path.join(dir, ".gemini")),
             "agy must not get a `.gemini/settings.json` it will never read"

      assert File.ls!(dir) == []
    end

    test "AgentConfig.write/3 propagates the agy refusal to the caller", %{dir: dir} do
      assert {:error, :unsupported} =
               AgentConfig.write(:gemini, dir, mcp_url: "u", scope_token: "t", cli: :agy)
    end

    test "cli_flavour/1 honours an explicit override and otherwise sniffs PATH", %{dir: _dir} do
      assert Gemini.cli_flavour(cli: :agy) == :agy
      assert Gemini.cli_flavour(cli: :gemini) == :gemini
      assert Gemini.cli_flavour([]) in [:agy, :gemini]
    end

    test "agy_config_map/1 emits agy's own mcp_config.json schema" do
      config =
        Gemini.agy_config_map(mcp_url: "http://127.0.0.1:4848/mcp", scope_token: "tok-agy")

      assert %{
               "mcpServers" => %{
                 "arbiter" => %{
                   "serverUrl" => "http://127.0.0.1:4848/mcp",
                   "headers" => %{"Authorization" => "Bearer tok-agy"}
                 }
               }
             } = config

      server = config["mcpServers"]["arbiter"]

      # agy names the client-side allowlist `enabledTools`; the upstream gemini
      # CLI names it `includeTools`. Neither accepts the other's key.
      assert "task_show" in server["enabledTools"]
      refute Map.has_key?(server, "includeTools")
      refute Map.has_key?(server, "httpUrl")
    end

    # bd-7s29yq (T6b): agy DOES read `$HOME/.gemini/config/mcp_config.json`, and
    # now that `Arbiter.Agents.Gemini.ConfigDir` owns a per-worktree `$HOME`
    # there is finally a token-safe place to put it. The worktree stays empty —
    # agy reads nothing from it either way.
    test "with an isolated agy HOME the config lands there, not in the worktree", %{dir: dir} do
      base = Path.join(System.tmp_dir!(), "mcp-agyhome-#{System.unique_integer([:positive])}")
      prev_enabled = Application.get_env(:arbiter, :worker_isolate_config)
      prev_root = Application.get_env(:arbiter, :worker_agy_home_root)
      Application.put_env(:arbiter, :worker_isolate_config, true)
      Application.put_env(:arbiter, :worker_agy_home_root, Path.join(base, "homes"))

      on_exit(fn ->
        Application.put_env(:arbiter, :worker_isolate_config, prev_enabled)

        if is_nil(prev_root),
          do: Application.delete_env(:arbiter, :worker_agy_home_root),
          else: Application.put_env(:arbiter, :worker_agy_home_root, prev_root)

        File.rm_rf(base)
      end)

      assert :ok =
               Gemini.write_mcp_config(dir,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-agy-home",
                 cli: :agy
               )

      refute File.exists?(Path.join(dir, ".gemini")),
             "the worktree must stay clean — agy never reads a worktree-local MCP config"

      home = Arbiter.Agents.Gemini.ConfigDir.path(worktree: dir)
      config = Jason.decode!(File.read!(Path.join(home, ".gemini/config/mcp_config.json")))

      assert config ==
               Gemini.agy_config_map(
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-agy-home"
               )
    end

    test "agy_config_map/1 omits enabledTools for coordinator scope" do
      config = Gemini.agy_config_map(mcp_url: "u", scope_token: "t", include_tools: nil)
      refute Map.has_key?(config["mcpServers"]["arbiter"], "enabledTools")
    end
  end

  describe "AgentConfig.write/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "mcp-agentcfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    end

    test "writes a parseable .mcp.json whose token verifies back to the spawn scope", %{dir: dir} do
      token = Scope.mint_worker(%{id: "bd-77", workspace_id: "ws-77"}, "shipyard")

      assert :ok =
               AgentConfig.write(:claude, dir,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: token,
                 server_name: "arbiter"
               )

      path = Path.join(dir, ".mcp.json")
      assert File.exists?(path)

      decoded = path |> File.read!() |> Jason.decode!()
      "Bearer " <> embedded = decoded["mcpServers"]["arbiter"]["headers"]["Authorization"]

      assert {:ok, scope} = Scope.from_token(embedded)
      assert scope.tier == :worker
      assert scope.task_id == "bd-77"
      assert scope.workspace_id == "ws-77"
    end

    test "writes a parseable .gemini/settings.json for the upstream `gemini` CLI", %{dir: dir} do
      token = Scope.mint_worker(%{id: "bd-88", workspace_id: "ws-88"}, "shipyard")

      assert :ok =
               AgentConfig.write(:gemini, dir,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: token,
                 cli: :gemini
               )

      path = Path.join([dir, ".gemini", "settings.json"])
      assert File.exists?(path)

      decoded = path |> File.read!() |> Jason.decode!()
      server = decoded["mcpServers"]["arbiter"]

      assert server["httpUrl"] == "http://127.0.0.1:4848/mcp"
      "Bearer " <> embedded = server["headers"]["Authorization"]
      assert {:ok, scope} = Scope.from_token(embedded)
      assert scope.task_id == "bd-88"

      assert is_list(server["includeTools"])
      assert "task_show" in server["includeTools"]
    end

    test "writes a .codex/config.toml for the :codex provider", %{dir: dir} do
      token = Scope.mint_worker(%{id: "bd-99", workspace_id: "ws-99"}, "shipyard")

      assert :ok =
               AgentConfig.write(:codex, dir,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: token
               )

      path = Path.join([dir, ".codex", "config.toml"])
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "[mcp_servers.arbiter]"
      assert content =~ "http://127.0.0.1:4848/mcp"
      assert content =~ "Bearer "
    end

    test "an unknown provider is a no-op (forward-safe), writing nothing", %{dir: dir} do
      assert :ok = AgentConfig.write(:unknown_provider_xyz, dir, mcp_url: "u", scope_token: "t")
      assert File.ls!(dir) == []
    end

    test "add_to_git_exclude/2 is a no-op (not an error) for a non-git directory", %{dir: dir} do
      assert :ok = AgentConfig.add_to_git_exclude(dir, [".mcp.json"])
    end

    test "adapter_for/1 resolves all registered providers" do
      assert AgentConfig.adapter_for(:claude) == Claude
      assert AgentConfig.adapter_for("claude") == Claude
      assert AgentConfig.adapter_for(:gemini) == Gemini
      assert AgentConfig.adapter_for("gemini") == Gemini
      assert AgentConfig.adapter_for(:codex) == Codex
      assert AgentConfig.adapter_for("codex") == Codex
    end

    test "adapter_for/1 returns nil for unknown providers" do
      assert AgentConfig.adapter_for(:nonsense_provider_xyz) == nil
      assert AgentConfig.adapter_for(nil) == nil
    end
  end

  # bd-9q966y: regression tests — injected agent-config must never be committable
  # via `git add -A` on a contributor repo that does NOT have .mcp.json in its
  # tracked .gitignore.
  describe "git exclude regression (bd-9q966y)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mcp-gitexcl-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      # Build a minimal real git repo with NO .mcp.json in .gitignore
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", tmp])
      {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", tmp, "config", "user.name", "Test"])
      {_, 0} = System.cmd("git", ["-C", tmp, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(tmp, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", tmp, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", tmp, "commit", "-q", "-m", "initial"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, repo: tmp}
    end

    test "write/3 for :claude adds .mcp.json to .git/info/exclude", %{repo: repo} do
      assert :ok =
               AgentConfig.write(:claude, repo,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-exclude-test"
               )

      # .mcp.json was written
      assert File.exists?(Path.join(repo, ".mcp.json"))

      # .git/info/exclude was populated with .mcp.json
      exclude_content = File.read!(Path.join([repo, ".git", "info", "exclude"]))
      assert exclude_content =~ ".mcp.json"
    end

    test "git add -A does NOT stage .mcp.json after write/3 for :claude", %{repo: repo} do
      assert :ok =
               AgentConfig.write(:claude, repo,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-add-test"
               )

      # `git add -A` should NOT stage .mcp.json (it's now in .git/info/exclude)
      {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])

      {status_out, 0} =
        System.cmd("git", ["-C", repo, "status", "--porcelain"], stderr_to_stdout: true)

      refute status_out =~ ".mcp.json",
             "expected .mcp.json to be excluded from git staging, got:\n#{status_out}"
    end

    test "write/3 for the `agy` CLI writes nothing and excludes nothing (bd-m8geh4)",
         %{repo: repo} do
      assert {:error, :unsupported} =
               AgentConfig.write(:gemini, repo,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-agy-excl",
                 cli: :agy
               )

      refute File.exists?(Path.join(repo, ".gemini"))

      exclude_path = Path.join([repo, ".git", "info", "exclude"])
      exclude_content = if File.exists?(exclude_path), do: File.read!(exclude_path), else: ""
      refute exclude_content =~ ".gemini/"
    end

    test "write/3 for the upstream `gemini` CLI adds .gemini/ to .git/info/exclude",
         %{repo: repo} do
      assert :ok =
               AgentConfig.write(:gemini, repo,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-gemini-excl",
                 cli: :gemini
               )

      exclude_content = File.read!(Path.join([repo, ".git", "info", "exclude"]))
      assert exclude_content =~ ".gemini/"

      # git add -A should not stage .gemini/settings.json
      {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])

      {status_out, 0} =
        System.cmd("git", ["-C", repo, "status", "--porcelain"], stderr_to_stdout: true)

      refute status_out =~ ".gemini",
             "expected .gemini/ to be excluded from git staging, got:\n#{status_out}"
    end

    test "write/3 for :codex adds .codex/ to .git/info/exclude", %{repo: repo} do
      assert :ok =
               AgentConfig.write(:codex, repo,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-codex-excl"
               )

      exclude_content = File.read!(Path.join([repo, ".git", "info", "exclude"]))
      assert exclude_content =~ ".codex/"
    end

    test "add_to_git_exclude/2 is idempotent — duplicate entries are not appended", %{repo: repo} do
      AgentConfig.add_to_git_exclude(repo, [".mcp.json"])
      AgentConfig.add_to_git_exclude(repo, [".mcp.json"])

      exclude_content = File.read!(Path.join([repo, ".git", "info", "exclude"]))
      count = exclude_content |> String.split(".mcp.json") |> length() |> Kernel.-(1)
      assert count == 1, "expected .mcp.json to appear exactly once, got #{count} occurrences"
    end
  end

  # bd-bhrji9: every test above uses a plain `git init` repo, where `--git-dir`
  # and `--git-common-dir` are identical. Real dispatches never run in one of
  # those — `Arbiter.Worker.Worktree.create/3` always provisions a *linked*
  # `git worktree add` worktree, where they differ. This describe block is the
  # regression case: it would have caught the original bug (`add_to_git_exclude/2`
  # resolving `--git-dir` — the worktree-PRIVATE admin dir — instead of
  # `--git-common-dir`, silently writing an `info/exclude` file git never reads
  # for ignore purposes, so `git add -A` staged `.mcp.json` anyway).
  describe "git exclude on a real linked worktree (bd-bhrji9)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mcp-gitexcl-wt-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      wt = Path.join(tmp, "wt")

      {_, 0} =
        System.cmd("git", ["-C", repo, "worktree", "add", wt, "-b", "feat"],
          stderr_to_stdout: true
        )

      # Confirm the fixture actually exercises the divergent case — a linked
      # worktree where git-dir != git-common-dir. If this ever coincides, the
      # test below would pass vacuously.
      {git_dir, 0} = System.cmd("git", ["-C", wt, "rev-parse", "--git-dir"])
      {common_dir, 0} = System.cmd("git", ["-C", wt, "rev-parse", "--git-common-dir"])
      assert String.trim(git_dir) != String.trim(common_dir)

      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, wt: wt, common_dir: String.trim(common_dir)}
    end

    test "write/3 for :claude excludes .mcp.json in the repo's common info/exclude, not the worktree-private one",
         %{wt: wt, common_dir: common_dir} do
      assert :ok =
               AgentConfig.write(:claude, wt,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-linked-worktree"
               )

      common_exclude = Path.join([common_dir, "info", "exclude"])
      assert File.exists?(common_exclude)
      assert File.read!(common_exclude) =~ ".mcp.json"
    end

    test "git add -A does NOT stage .mcp.json in a linked worktree after write/3", %{wt: wt} do
      assert :ok =
               AgentConfig.write(:claude, wt,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-linked-worktree-add"
               )

      {_, 0} = System.cmd("git", ["-C", wt, "add", "-A"])

      {status_out, 0} =
        System.cmd("git", ["-C", wt, "status", "--porcelain"], stderr_to_stdout: true)

      refute status_out =~ ".mcp.json",
             "expected .mcp.json to be excluded from git staging in a linked worktree, got:\n#{status_out}"
    end
  end
end
