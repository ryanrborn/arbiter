defmodule ArbiterCli.AliasResolverTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.AliasResolver

  describe "resolve/1 — known verbs (no HTTP needed)" do
    for verb <- AliasResolver.known_verbs() do
      test "known verb #{verb} resolves to itself" do
        # Note: no stub set; if AliasResolver tried to hit the API this would 500.
        assert {:ok, unquote(verb)} = AliasResolver.resolve(unquote(verb))
      end
    end
  end

  describe "resolve/1 — alias lookup" do
    test "aliased verb resolves to its canonical when canonical is built-in" do
      stub_get("/api/workspaces", %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "config" => %{
              "vernacular" => %{"aliases" => %{"deploy" => "close"}}
            }
          }
        ]
      })

      assert {:ok, "close"} = AliasResolver.resolve("deploy")
    end

    test "alias mapping to a non-built-in canonical is treated as unknown" do
      stub_get("/api/workspaces", %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "config" => %{
              "vernacular" => %{"aliases" => %{"deploy" => "fly"}}
            }
          }
        ]
      })

      assert {:unknown, _} = AliasResolver.resolve("deploy")
    end

    test "unknown verb with no aliases returns built-in suggestions" do
      stub_get("/api/workspaces", %{
        "data" => [%{"id" => "ws-1", "name" => "default", "config" => %{}}]
      })

      assert {:unknown, suggestions} = AliasResolver.resolve("clse")
      assert "close" in suggestions
    end

    test "unknown verb with aliases returns built-ins + alias keys as candidates" do
      stub_get("/api/workspaces", %{
        "data" => [
          %{
            "id" => "ws-1",
            "name" => "default",
            "config" => %{
              "vernacular" => %{"aliases" => %{"deploy" => "close", "muster" => "ready"}}
            }
          }
        ]
      })

      assert {:unknown, suggestions} = AliasResolver.resolve("deplo")
      assert "deploy" in suggestions
    end

    test "workspace lookup failure: falls back to built-in suggestions" do
      stub_get("/api/workspaces", %{"error" => "boom"}, 500)

      assert {:unknown, suggestions} = AliasResolver.resolve("clse")
      assert "close" in suggestions
    end
  end

  describe "suggest/2 — distance-ranked suggestions" do
    test "returns the closest matches first, capped at 3" do
      candidates = ~w(show create close list update dep ready doctor where)
      suggestions = AliasResolver.suggest("clse", candidates)
      assert hd(suggestions) == "close"
      assert length(suggestions) <= 3
    end

    test "excludes candidates whose distance exceeds the threshold" do
      candidates = ~w(elephant raspberry octopus)
      # 'show' is far from all of these → no suggestions
      suggestions = AliasResolver.suggest("show", candidates)
      assert suggestions == []
    end

    test "an exact match comes first with distance 0" do
      [first | _] = AliasResolver.suggest("ready", ~w(show create ready close))
      assert first == "ready"
    end

    test "empty candidate list returns empty list" do
      assert AliasResolver.suggest("anything", []) == []
    end
  end
end
