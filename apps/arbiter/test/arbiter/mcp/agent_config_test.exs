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

    test "writes a parseable .gemini/settings.json for the :gemini provider", %{dir: dir} do
      token = Scope.mint_worker(%{id: "bd-88", workspace_id: "ws-88"}, "shipyard")

      assert :ok =
               AgentConfig.write(:gemini, dir,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: token
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

    test "write/3 for :gemini adds .gemini/ to .git/info/exclude", %{repo: repo} do
      assert :ok =
               AgentConfig.write(:gemini, repo,
                 mcp_url: "http://127.0.0.1:4848/mcp",
                 scope_token: "tok-gemini-excl"
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
end
