defmodule ArbiterCli.AliasResolverTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.AliasResolver

  describe "resolve/1 — known resources/commands" do
    for verb <- AliasResolver.known_verbs() do
      test "known verb #{verb} resolves to itself" do
        assert {:ok, unquote(verb)} = AliasResolver.resolve(unquote(verb))
      end
    end
  end

  describe "resolve/1 — unknown tokens" do
    test "unknown token returns resource suggestions" do
      assert {:unknown, suggestions} = AliasResolver.resolve("isue")
      assert "issue" in suggestions
    end

    test "a token with no close match returns no suggestions" do
      assert {:unknown, []} = AliasResolver.resolve("zzzzzz")
    end

    test "themed words are no longer aliased — they resolve as unknown" do
      assert {:unknown, _} = AliasResolver.resolve("bead")
    end

    test "worker is now a real command — not a themed alias" do
      assert {:ok, "worker"} = AliasResolver.resolve("worker")
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
