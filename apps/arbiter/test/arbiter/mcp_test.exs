defmodule Arbiter.MCPTest do
  use ExUnit.Case, async: true

  alias Arbiter.MCP

  describe "configuration" do
    test "the server is enabled by default in the suite" do
      assert MCP.enabled?()
    end

    test "spawn-time config injection is disabled in the suite (config/test.exs)" do
      refute MCP.inject_config?()
    end

    test "server_url derives a loopback /mcp endpoint from the configured port" do
      assert MCP.server_url() =~ ~r{^http://127\.0\.0\.1:\d+/mcp$}
    end

    test "server_name and server_version have sane defaults" do
      assert MCP.server_name() == "arbiter"
      assert is_binary(MCP.server_version())
    end
  end

  describe "mint/2 + verify/2" do
    test "round-trips a claims map" do
      token = MCP.mint(%{tier: :coordinator, workspace_id: "w"})
      assert {:ok, %{tier: :coordinator, workspace_id: "w"}} = MCP.verify(token)
    end

    test "a tampered token is invalid" do
      token = MCP.mint(%{tier: :worker, workspace_id: "w"})
      assert {:error, :invalid} = MCP.verify(token <> "x")
    end

    test "max_age is enforced at verify time" do
      token = MCP.mint(%{tier: :worker, workspace_id: "w"})
      assert {:error, :expired} = MCP.verify(token, max_age: -1)
    end
  end
end
