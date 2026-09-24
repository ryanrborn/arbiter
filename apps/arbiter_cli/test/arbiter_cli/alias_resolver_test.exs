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
    test "every verb in Main.dispatch_known/2 is in @known_verbs" do
      # Extract all verbs handled by dispatch_known/2 from the Main module's
      # source. This ensures the test itself cannot drift: adding a new
      # dispatch_known clause will automatically fail the test if the verb
      # is not in @known_verbs.
      main_source_path = Path.join([__DIR__, "..", "..", "lib", "arbiter_cli", "main.ex"])
      main_source = File.read!(main_source_path)

      verb_pattern = ~r/defp dispatch_known\("([^"]+)"/

      dispatch_verbs =
        verb_pattern
        |> Regex.scan(main_source, capture: :all_but_first)
        |> Enum.map(&hd/1)
        |> Enum.sort()
        |> Enum.uniq()

      known = AliasResolver.known_verbs()

      for verb <- dispatch_verbs do
        assert verb in known,
               "dispatch_known(\"#{verb}\", ...) in Main is not in AliasResolver.@known_verbs; " <>
                 "every dispatched verb must be resolvable before dispatch"
      end
    end
  end
end
