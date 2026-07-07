defmodule Arbiter.AgentsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents
  alias Arbiter.Agents.Claude
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  describe "for_workspace/1 and for_type/1" do
    test "returns Claude for the default workspace (no `agent` key)" do
      ws = %Workspace{config: %{}}
      assert Agents.for_workspace(ws) == Claude
    end

    test "returns Claude when `agent.type` is `claude`" do
      ws = %Workspace{config: %{"agent" => %{"type" => "claude"}}}
      assert Agents.for_workspace(ws) == Claude
    end

    test "returns Claude for nil workspace (back-compat path)" do
      assert Agents.for_workspace(nil) == Claude
    end

    test "for_type/:claude resolves to the Claude adapter" do
      assert Agents.for_type(:claude) == Claude
    end

    test "for_type/:codex resolves to the Codex adapter" do
      assert Agents.for_type(:codex) == Arbiter.Agents.Codex
    end

    test "for_type/1 raises for unregistered types (aider not shipped)" do
      assert_raise ArgumentError, ~r/no agent adapter registered for :aider/, fn ->
        Agents.for_type(:aider)
      end
    end
  end

  describe "for_task/2" do
    test "falls back to the workspace adapter when task has no per-task override" do
      task = %Issue{}
      ws = %Workspace{config: %{}}
      assert Agents.for_task(task, ws) == Claude
    end
  end

  describe "reviewer_for_workspace/1" do
    test "falls back to the worker adapter when `review_agent` is absent" do
      ws = %Workspace{config: %{"agent" => %{"type" => "claude"}}}
      assert Agents.reviewer_for_workspace(ws) == Claude
    end

    test "uses `review_agent.type` when set" do
      ws = %Workspace{config: %{"review_agent" => %{"type" => "claude"}}}
      assert Agents.reviewer_for_workspace(ws) == Claude
    end
  end

  describe "adapters/0 + valid_agent_types/0" do
    test "adapters/0 exposes the registered map" do
      assert Agents.adapters() == %{
               claude: Claude,
               gemini: Arbiter.Agents.Gemini,
               codex: Arbiter.Agents.Codex
             }
    end

    test "valid_agent_types/0 is `[\"claude\", \"gemini\", \"codex\"]`" do
      assert Agents.valid_agent_types() == ["claude", "gemini", "codex"]
    end
  end

  describe "prepare/1 + prepare/2" do
    setup do
      on_exit(fn ->
        Claude.Config.clear()
        Arbiter.Agents.Gemini.Config.clear()
        Arbiter.Agents.Codex.Config.clear()
      end)

      :ok
    end

    test "nil workspace clears the per-process active config" do
      Claude.Config.put_active(%{"model" => "opus"})
      Arbiter.Agents.Gemini.Config.put_active(%{"model" => "gemini-medium"})
      Arbiter.Agents.Codex.Config.put_active(%{"model" => "gpt-5-codex"})
      assert Claude.Config.active_model() == "opus"
      assert Arbiter.Agents.Gemini.Config.active_model() == "gemini-medium"
      assert Arbiter.Agents.Codex.Config.active_model() == "gpt-5-codex"

      assert Agents.prepare(nil) == :ok
      assert Claude.Config.active_model() == nil
      assert Arbiter.Agents.Gemini.Config.active_model() == nil
      assert Arbiter.Agents.Codex.Config.active_model() == nil
    end

    test "seeds configurations from the workspace `agent.config`" do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
        }
      }

      assert Agents.prepare(ws) == :ok
      assert Claude.Config.active_model() == "sonnet"
      assert Arbiter.Agents.Gemini.Config.active_model() == "sonnet"
      assert Arbiter.Agents.Codex.Config.active_model() == "sonnet"
    end

    test "prepare/2 with :review_agent seeds the reviewer config block" do
      ws = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
          "review_agent" => %{"type" => "claude", "config" => %{"model" => "opus"}}
        }
      }

      assert Agents.prepare(ws, :review_agent) == :ok
      assert Claude.Config.active_model() == "opus"
      assert Arbiter.Agents.Gemini.Config.active_model() == "opus"
    end
  end
end
