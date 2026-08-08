defmodule Arbiter.Skills.InvocationParserTest do
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Skills
  alias Arbiter.Skills.InvocationParser

  describe "extract_skill_names without registered skills" do
    test "unregistered slash invocation counts nothing (skill not in DB)" do
      line = "/tdd is required for this task"
      {found, failed} = InvocationParser.parse_and_update(nil, [line])

      assert found == 0
      assert failed == 0
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

    defp invoke_count(skill) do
      query = Ash.Query.filter(Skills.Usage, skill_id == ^skill.id)
      {:ok, usage} = Ash.read_one(query)
      usage && usage.invoke_count
    end

    test "increments invoke_count from a Skill tool_use transcript line (current format)",
         %{skill1: skill1} do
      # Matches Arbiter.Worker.ClaudeSession.assistant_block_lines/1's current
      # rendering of a Skill tool_use block (summarize_tool_input/1 special-cases
      # the "skill" input key).
      lines = ["⏵ Skill(test-invoke-skill-1)"]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "increments invoke_count from a Skill tool_use line even with a long args value",
         %{skill1: skill1} do
      # Regression: previously the transcript rendering fell through to
      # Jason.encode!/1, and a long "args" value (which sorts before "skill"
      # in Erlang key order) could push "skill":"..." past a length-based
      # truncation cutoff, silently dropping the invocation.
      lines = ["⏵ Skill(test-invoke-skill-1)"]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "increments invoke_count from the legacy JSON Skill tool_use rendering (old transcripts)",
         %{skill1: skill1} do
      lines = [~s|⏵ Skill({"skill":"test-invoke-skill-1"})|]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "legacy JSON Skill tool_use detector is order-independent on the input map's other keys",
         %{skill1: skill1} do
      lines = [~s|⏵ Skill({"args":"do the thing","skill":"test-invoke-skill-1"})|]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "slash invocation at line start increments the matching skill",
         %{skill1: skill1} do
      lines = ["/test-invoke-skill-1 is required for this task"]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "backtick-wrapped mid-sentence slash mention increments the matching skill",
         %{skill1: skill1} do
      lines = ["I will invoke `/test-invoke-skill-1` now"]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "unwrapped mid-sentence slash mention does NOT count (avoids path/URL collisions)",
         %{skill1: skill1} do
      lines = ["I will invoke /test-invoke-skill-1 now"]
      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 0
      assert invoke_count(skill1) == nil
    end

    test "path-like mid-sentence tokens are not credited to a same-named skill" do
      {:ok, tmp_skill} = Skills.create_skill(%{name: "tmp", body: "test"})

      lines = [
        "cd /tmp && ls",
        "check /proc for details",
        "curl https://example.com/api/data"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 0
      assert invoke_count(tmp_skill) == nil
    end

    test "relative path ./name is not credited to a same-named skill (leading dot is not a wrap)" do
      {:ok, deps_skill} = Skills.create_skill(%{name: "deps", body: "test"})

      lines = ["⏵ Bash(find . -path ./deps -prune -o -print)"]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 0
      assert invoke_count(deps_skill) == nil
    end

    test "quoted string literal /name in source code is not credited to a same-named skill" do
      {:ok, api_skill} = Skills.create_skill(%{name: "api", body: "test"})

      lines = ["scope \"/api\", ArbiterWeb.Api do"]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 0
      assert invoke_count(api_skill) == nil
    end

    test "increments for multiple different skills on separate lines",
         %{skill1: skill1, skill2: skill2} do
      lines = [
        "/test-invoke-skill-1 for the first skill",
        "/test-invoke-skill-2 for the second skill"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 2
      assert invoke_count(skill1) == 1
      assert invoke_count(skill2) == 1
    end

    test "deduplicates multiple invocations of same skill on same line", %{skill1: skill1} do
      line =
        "/test-invoke-skill-1 then /test-invoke-skill-1 again then /test-invoke-skill-1 once more"

      {found, _failed} = InvocationParser.parse_and_update(nil, [line])

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "handles mixed valid names and invalid (non-kebab-case) names", %{skill1: skill1} do
      lines = [
        "/test-invoke-skill-1 is valid",
        "/UPPERCASE is not",
        "/double--dash is not"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      assert found == 1
      assert invoke_count(skill1) == 1
    end

    test "handles bundled/unregistered skills gracefully alongside a registered one",
         %{skill1: skill1} do
      lines = [
        "/test-invoke-skill-1 is in our registry",
        "/code-review is a bundled skill and should not fail parsing"
      ]

      {found, _failed} = InvocationParser.parse_and_update(nil, lines)

      # code-review is not in our DB but should not cause an error
      assert found == 1
      assert invoke_count(skill1) == 1
    end
  end
end
