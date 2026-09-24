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
      assert {:unknown, _} = AliasResolver.resolve("task")
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

  describe "consistency — every dispatched verb is resolvable" do
    # This list must match every verb in Main.dispatch_known/2.
    # If you add a dispatch_known clause, add the verb here and to @known_verbs.
    @dispatched_verbs ~w(issue worker repo dep config server workspace message usage loop queue scheduler quota preflip-gate breaker install mcp skill account session dispatch verify prime where init version self-update upgrade)

    test "all dispatched verbs are known" do
      known = AliasResolver.known_verbs()

      for verb <- @dispatched_verbs do
        assert verb in known,
               "dispatch_known(\"#{verb}\", ...) is not in @known_verbs; " <>
                 "verbs must be resolvable before dispatch"
      end
    end
  end
end
