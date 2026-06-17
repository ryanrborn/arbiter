defmodule Arbiter.MCP.AgentConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP.AgentConfig
  alias Arbiter.MCP.AgentConfig.Claude
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

    test "an unknown provider is a no-op (forward-safe), writing nothing", %{dir: dir} do
      assert :ok = AgentConfig.write(:gemini, dir, mcp_url: "u", scope_token: "t")
      refute File.exists?(Path.join(dir, ".mcp.json"))
    end

    test "adapter_for/1 resolves claude and rejects unknowns" do
      assert AgentConfig.adapter_for(:claude) == Claude
      assert AgentConfig.adapter_for("claude") == Claude
      assert AgentConfig.adapter_for(:nonsense_provider_xyz) == nil
      assert AgentConfig.adapter_for(nil) == nil
    end
  end
end
