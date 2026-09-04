defmodule Arbiter.Loop.FindingBucketsTest do
  # The controlled vocabulary and the category -> skill attribution table that
  # now sits beside it (bd-5w8h0r). The table is fingerprint-load-bearing, so
  # the tests that matter most are the total-coverage ones.
  use ExUnit.Case, async: true

  alias Arbiter.Loop.FindingBuckets

  describe "categories/0" do
    test "is the closed set: every regex bucket plus context exhaustion" do
      categories = FindingBuckets.categories()

      assert FindingBuckets.context_exhaustion_category() in categories
      assert "missing test coverage" in categories
      assert "plausible code, green tests, inert at runtime" in categories
      assert "regression in existing behaviour" in categories
      assert "secret / credential exposure" in categories
      assert length(categories) == 5
    end

    test "every category the analyser can emit resolves to an attribution" do
      for category <- FindingBuckets.categories() do
        assert %{kind: kind, skill: skill, imperative: imperative} =
                 FindingBuckets.attribution(category),
               "#{category} has no attribution row"

        assert kind in [:skill_patch, :skill_create]
        assert is_binary(skill) and skill =~ ~r/^[a-z0-9-]+$/
        assert is_binary(imperative) and String.length(imperative) > 20
      end
    end

    test "every bucketable finding text resolves to an attribution" do
      # The regexes and the table are two halves of one map; a finding that
      # buckets but does not attribute is the drift this pairing exists to
      # prevent.
      for text <- [
            "no test for the error branch",
            "leaked a credential",
            "breaks existing behaviour",
            "green tests but never wired"
          ] do
        assert {category, ^text} = FindingBuckets.bucket_finding(text)
        assert FindingBuckets.attribution(category)
      end
    end
  end

  describe "attribution/1" do
    test "homes the three categories an existing fleet skill governs" do
      assert %{kind: :skill_patch, skill: "verification-before-completion"} =
               FindingBuckets.attribution("plausible code, green tests, inert at runtime")

      assert %{kind: :skill_patch, skill: "test-driven-development"} =
               FindingBuckets.attribution("missing test coverage")

      assert %{kind: :skill_patch, skill: "test-driven-development"} =
               FindingBuckets.attribution("regression in existing behaviour")
    end

    test "routes the two unhomed categories to :skill_create, not to a nonexistent skill" do
      assert %{kind: :skill_create} = FindingBuckets.attribution("secret / credential exposure")

      assert %{kind: :skill_create} =
               FindingBuckets.attribution(FindingBuckets.context_exhaustion_category())
    end

    test "an unknown category attributes to nothing rather than guessing" do
      assert FindingBuckets.attribution("some category no bucket produces") == nil
    end
  end
end
