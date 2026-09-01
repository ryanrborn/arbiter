defmodule Arbiter.Trackers.Jira.ConfigTest do
  use ExUnit.Case, async: false

  alias Arbiter.Trackers.Jira.Config

  @host "leotechnologies.atlassian.net"
  @project "VR"
  @env_var "GTE_JIRA_CONFIG_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-jira-token")

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp resolve!(extra) do
    Config.put_active(
      Map.merge(
        %{
          "host" => @host,
          "project_key" => @project,
          "credentials_ref" => "env:#{@env_var}",
          "email" => "tester@example.com"
        },
        extra
      )
    )

    Config.resolve!()
  end

  describe "transition_graph/1" do
    test "keeps edges that name only a destination status" do
      # The route is what matters — the transition name is an optional
      # tie-break hint, so a name-less edge is valid config (bd-bwwkvr).
      cfg = resolve!(%{"transition_graph" => %{"Backlog" => [%{"to" => "To Do"}]}})

      assert cfg.transition_graph == %{"Backlog" => [%{"to" => "To Do"}]}
    end

    test "drops edges with no destination status" do
      cfg =
        resolve!(%{
          "transition_graph" => %{
            "Backlog" => [%{"transition" => "To do next"}, %{"to" => "To Do"}]
          }
        })

      assert cfg.transition_graph == %{"Backlog" => [%{"to" => "To Do"}]}
    end

    test "the shipped default routes Backlog to In Progress without naming a dead end" do
      cfg = resolve!(%{})
      graph = cfg.transition_graph

      # Every default edge must at least declare where it lands.
      for {_from, edges} <- graph, edge <- edges do
        assert is_binary(edge["to"]) and edge["to"] != ""
      end

      assert {:ok, hops} =
               Arbiter.Trackers.Jira.plan_transition_path(graph, "Backlog", "In Progress")

      assert Enum.map(hops, & &1["to"]) == ["To Do", "In Progress"]
    end
  end
end
