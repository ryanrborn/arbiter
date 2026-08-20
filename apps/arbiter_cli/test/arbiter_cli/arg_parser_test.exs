defmodule ArbiterCli.ArgParserTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.ArgParser

  describe "parse/2" do
    test "splits flags from positionals and defaults mode to :text" do
      {opts, rest, mode} =
        ArgParser.parse(["foo", "--reason", "because"], switches: [reason: :string])

      assert opts[:reason] == "because"
      assert rest == ["foo"]
      assert mode == :text
    end

    test "detects --json and reports :json mode without needing it declared explicitly" do
      {opts, rest, mode} = ArgParser.parse(["--json", "foo"], switches: [reason: :string])

      assert opts[:json] == true
      assert rest == ["foo"]
      assert mode == :json
    end

    test "passes through aliases" do
      {opts, _rest, _mode} =
        ArgParser.parse(["-r", "because"], switches: [reason: :string], aliases: [r: :reason])

      assert opts[:reason] == "because"
    end

    test "honors an explicit :strict switches list (rejects unknown flags)" do
      {opts, rest, _mode} =
        ArgParser.parse(["foo", "--reason", "because"], strict: [reason: :string, json: :boolean])

      assert opts[:reason] == "because"
      assert rest == ["foo"]
    end
  end

  describe "unless_help/3" do
    test "runs the function when --help/-h is absent" do
      assert ArgParser.unless_help(["foo"], "usage text", fn -> :ran end) == :ran
    end

    test "prints usage and does not run the function when --help is present" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          refute ArgParser.unless_help(["--help"], "usage text", fn -> flunk("should not run") end) ==
                   :ran
        end)

      assert output =~ "usage text"
    end

    test "prints usage and does not run the function when -h is present" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ArgParser.unless_help(["-h"], "usage text", fn -> flunk("should not run") end)
        end)

      assert output =~ "usage text"
    end
  end
end
