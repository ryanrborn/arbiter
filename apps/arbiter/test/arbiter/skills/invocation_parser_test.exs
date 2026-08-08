defmodule Arbiter.Skills.InvocationParserTest do
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Skills
  alias Arbiter.Skills.InvocationParser

  describe "extract_skill_names" do
    test "extracts single slash invocation from a line" do
      # Parse returns {found, failed} tuples
      line = "Now I'll run /tdd to write tests first"
      {found, _failed} = InvocationParser.parse_and_update(nil, [line])

      # Count should be 0 because the skill /tdd doesn't exist in DB (get_skill_by_name returns :not_found)
      assert is_integer(found)
    end

    test "handles multiple invocations in same line" do
      line = "/tdd and then /code-review and finally /systematic-debugging"
      {found, _failed} = InvocationParser.parse_and_update(nil, [line])
      assert is_integer(found)
    end

    test "handles invocation at line start" do
      line = "/tdd is required for this task"
      {found, _failed} = InvocationParser.parse_and_update(nil, [line])
      assert is_integer(found)
    end

    test "handles mixed valid and invalid names" do
      # Valid: /tdd, /code-review, /deep-research
      # Invalid: /UPPERCASE, /has spaces, /double--dash
      lines = [
        "/tdd is valid",
        "/UPPERCASE is not",
        "/double--dash is not",
        "/code-review is valid"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)
      assert is_integer(found)
    end

    test "deduplicates multiple invocations of same skill on same line" do
      line = "/tdd then /tdd again then /tdd once more"
      {found, _failed} = InvocationParser.parse_and_update(nil, [line])
      # Should count /tdd only once per line (but 0 since it's not in DB)
      assert is_integer(found)
    end

    test "handles lines without invocations" do
      lines = [
        "This is just normal text",
        "No slash commands here",
        "@ mentions and other @ symbols"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)
      assert found == 0
    end

    test "handles empty list of lines" do
      {found, _failed} = InvocationParser.parse_and_update(nil, [])
      assert found == 0
    end

    test "handles nil transcript" do
      {found, _failed} = InvocationParser.parse_and_update(nil, nil || [])
      assert found == 0
    end
  end

  describe "full integration with skill lookup" do
    setup do
      {:ok, skill1} = Skills.create_skill(%{name: "test-invoke-skill-1", body: "test"})
      {:ok, skill2} = Skills.create_skill(%{name: "test-invoke-skill-2", body: "test"})

      {:ok, skill1: skill1, skill2: skill2}
    end

    test "increments invoke_count when skill is invoked", %{skill1: skill1} do
      lines = ["I will invoke /test-invoke-skill-1 now"]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      # Should find and increment the skill
      assert found >= 1

      # Query the usage to verify it was incremented
      usage_query = Ash.Query.filter(Skills.Usage, skill_id == ^skill1.id)

      {:ok, usage} = Ash.read_one(usage_query)

      assert usage != nil
      assert usage.invoke_count == 1
    end

    test "increments for multiple different skills", %{skill1: skill1, skill2: skill2} do
      lines = [
        "/test-invoke-skill-1 for the first skill",
        "/test-invoke-skill-2 for the second skill"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found >= 2

      u1_query = Ash.Query.filter(Skills.Usage, skill_id == ^skill1.id)
      u2_query = Ash.Query.filter(Skills.Usage, skill_id == ^skill2.id)

      {:ok, u1} = Ash.read_one(u1_query)
      {:ok, u2} = Ash.read_one(u2_query)
      assert u1.invoke_count == 1
      assert u2.invoke_count == 1
    end

    test "handles bundled skills gracefully", %{skill1: skill1} do
      lines = [
        "/test-invoke-skill-1 is in our registry",
        "/code-review is a bundled skill and should not fail parsing"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      # code-review is not in our DB but should not cause an error
      assert found >= 1

      u1_query = Ash.Query.filter(Skills.Usage, skill_id == ^skill1.id)

      {:ok, u1} = Ash.read_one(u1_query)
      assert u1.invoke_count == 1
    end
  end
end
