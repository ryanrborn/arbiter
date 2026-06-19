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

    test "includes the polecat-tier includeTools allowlist by default" do
      config = Gemini.config_map(mcp_url: "u", scope_token: "t")
      tools = config["mcpServers"]["arbiter"]["includeTools"]

      assert is_list(tools)
      assert "bead_show" in tools
      assert "bead_update_progress" in tools
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
        Gemini.config_map(mcp_url: "u", scope_token: "t", include_tools: ["bead_show"])

      assert config["mcpServers"]["arbiter"]["includeTools"] == ["bead_show"]
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
      token = Scope.mint_polecat(%{id: "bd-77", workspace_id: "ws-77"}, "shipyard")

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
      assert scope.tier == :polecat
      assert scope.bead_id == "bd-77"
      assert scope.workspace_id == "ws-77"
    end

    test "writes a parseable .gemini/settings.json for the :gemini provider", %{dir: dir} do
      token = Scope.mint_polecat(%{id: "bd-88", workspace_id: "ws-88"}, "shipyard")

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
      assert scope.bead_id == "bd-88"

      assert is_list(server["includeTools"])
      assert "bead_show" in server["includeTools"]
    end

    test "writes a .codex/config.toml for the :codex provider", %{dir: dir} do
      token = Scope.mint_polecat(%{id: "bd-99", workspace_id: "ws-99"}, "shipyard")

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
end
