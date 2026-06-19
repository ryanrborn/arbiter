defmodule ArbiterCli.AliasResolverTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.AliasResolver

  describe "resolve/1 — known resources/commands (no HTTP needed)" do
    for verb <- AliasResolver.known_verbs() do
      test "known verb #{verb} resolves to itself" do
        # Note: no stub set; if AliasResolver tried to hit the API this would 500.
        assert {:ok, unquote(verb)} = AliasResolver.resolve(unquote(verb))
      end
    end
  end

  describe "resolve/1 — built-in default vernacular (Sith resource names)" do
    test "the default themed resource names resolve to their canonical base offline" do
      # Empty server vernacular — only the built-in defaults apply.
      stub_get("/api/settings", %{"data" => %{"vernacular" => %{}}})

      assert {:ok, "worker"} = AliasResolver.resolve("polecat")
      assert {:ok, "issue"} = AliasResolver.resolve("bead")
      assert {:ok, "repo"} = AliasResolver.resolve("warship")
      assert {:ok, "dispatch"} = AliasResolver.resolve("sling")
    end

    test "default aliases resolve even when the server is unreachable" do
      stub_get("/api/settings", %{"error" => "boom"}, 500)

      assert {:ok, "worker"} = AliasResolver.resolve("polecat")
      assert {:ok, "dispatch"} = AliasResolver.resolve("sling")
    end

    test "matching is case-insensitive on the typed token" do
      stub_get("/api/settings", %{"data" => %{"vernacular" => %{}}})

      assert {:ok, "worker"} = AliasResolver.resolve("Polecat")
      assert {:ok, "issue"} = AliasResolver.resolve("BEAD")
    end
  end

  describe "resolve/1 — server vernacular layered on the defaults" do
    test "a workspace label aliases its canonical resource" do
      stub_get("/api/settings", %{
        "data" => %{"vernacular" => %{"worker" => "acolyte"}}
      })

      assert {:ok, "worker"} = AliasResolver.resolve("acolyte")
      # the built-in default still resolves too
      assert {:ok, "worker"} = AliasResolver.resolve("polecat")
    end

    test "a label whose key is a verb aliases the command verb" do
      stub_get("/api/settings", %{
        "data" => %{"vernacular" => %{"dispatch" => "throw"}}
      })

      assert {:ok, "dispatch"} = AliasResolver.resolve("throw")
      assert {:ok, "dispatch"} = AliasResolver.resolve("THROW")
    end

    test "a vernacular entry whose key is not a known resource is not aliased" do
      stub_get("/api/settings", %{
        "data" => %{"vernacular" => %{"epic" => "campaign"}}
      })

      # "epic" is not a resource, so its label "campaign" aliases nothing.
      assert {:unknown, _} = AliasResolver.resolve("campaign")
    end

    test "a label equal to its key creates no self-alias" do
      stub_get("/api/settings", %{
        "data" => %{"vernacular" => %{"issue" => "issue"}}
      })

      # The default bead->issue still applies, but "issue" the literal label
      # of itself is not a separate alias.
      assert {:ok, "issue"} = AliasResolver.resolve("bead")
    end
  end

  describe "resolve/1 — explicit aliases" do
    test "an explicit alias resolves to its canonical when canonical is known" do
      stub_get("/api/settings", %{
        "data" => %{"vernacular" => %{"aliases" => %{"deploy" => "server"}}}
      })

      assert {:ok, "server"} = AliasResolver.resolve("deploy")
    end

    test "an explicit alias to a non-known canonical is treated as unknown" do
      stub_get("/api/settings", %{
        "data" => %{"vernacular" => %{"aliases" => %{"deploy" => "fly"}}}
      })

      assert {:unknown, _} = AliasResolver.resolve("deploy")
    end

    test "explicit aliases win over derived label aliases on conflict" do
      stub_get("/api/settings", %{
        "data" => %{
          "vernacular" => %{
            "dispatch" => "throw",
            "aliases" => %{"throw" => "issue"}
          }
        }
      })

      assert {:ok, "issue"} = AliasResolver.resolve("throw")
    end
  end

  describe "resolve/1 — unknown tokens" do
    test "unknown token returns resource suggestions" do
      stub_get("/api/settings", %{"data" => %{"vernacular" => %{}}})

      assert {:unknown, suggestions} = AliasResolver.resolve("isue")
      assert "issue" in suggestions
    end

    test "unknown token with aliases returns built-ins + alias keys as candidates" do
      stub_get("/api/settings", %{
        "data" => %{"vernacular" => %{"aliases" => %{"deploy" => "server"}}}
      })

      assert {:unknown, suggestions} = AliasResolver.resolve("deplo")
      assert "deploy" in suggestions
    end
  end

  describe "verb_aliases/0" do
    test "combines the built-in defaults, derived labels, and explicit aliases" do
      stub_get("/api/settings", %{
        "data" => %{
          "vernacular" => %{
            "dispatch" => "throw",
            "aliases" => %{"deploy" => "server"}
          }
        }
      })

      aliases = AliasResolver.verb_aliases()
      assert aliases["polecat"] == "worker"
      assert aliases["throw"] == "dispatch"
      assert aliases["deploy"] == "server"
    end

    test "falls back to the built-in defaults when the workspace can't be reached" do
      stub_get("/api/settings", %{"error" => "boom"}, 500)

      assert AliasResolver.verb_aliases() == AliasResolver.default_aliases()
    end
  end

  describe "suggest/2 — distance-ranked suggestions" do
    test "returns the closest matches first, capped at 3" do
      candidates = ~w(issue worker batch repo dep config server workspace)
      suggestions = AliasResolver.suggest("isue", candidates)
      assert hd(suggestions) == "issue"
      assert length(suggestions) <= 3
    end

    test "excludes candidates whose distance exceeds the threshold" do
      candidates = ~w(elephant raspberry octopus)
      suggestions = AliasResolver.suggest("repo", candidates)
      assert suggestions == []
    end

    test "an exact match comes first with distance 0" do
      [first | _] = AliasResolver.suggest("worker", ~w(issue worker batch repo))
      assert first == "worker"
    end

    test "empty candidate list returns empty list" do
      assert AliasResolver.suggest("anything", []) == []
    end
  end
end
