defmodule Arbiter.RedactionTest do
  use ExUnit.Case, async: true

  alias Arbiter.Redaction

  describe "redact/2" do
    test "replaces a secret value with the placeholder" do
      assert Redaction.redact("token is sk-abc123 here", ["sk-abc123"]) ==
               "token is [REDACTED] here"
    end

    test "replaces every occurrence of a secret" do
      assert Redaction.redact("sk-abc sk-abc", ["sk-abc"]) == "[REDACTED] [REDACTED]"
    end

    test "redacts multiple distinct secrets" do
      assert Redaction.redact("a=SEC1 b=SEC2", ["SEC1", "SEC2"]) ==
               "a=[REDACTED] b=[REDACTED]"
    end

    test "redacts the longer of two overlapping secrets first" do
      # "SEC" is a substring of "SECRETLONG"; the longer value must win so we
      # never leave a trailing fragment of the longer secret in the clear.
      assert Redaction.redact("value=SECRETLONG", ["SEC", "SECRETLONG"]) ==
               "value=[REDACTED]"
    end

    test "ignores empty and nil secret values (never blanks the whole line)" do
      assert Redaction.redact("unchanged text", ["", nil]) == "unchanged text"
    end

    test "no secrets is a passthrough" do
      assert Redaction.redact("unchanged text", []) == "unchanged text"
    end

    test "a non-binary input is returned unchanged" do
      assert Redaction.redact(nil, ["x"]) == nil
    end

    test "leaves a line with no secret occurrence untouched" do
      assert Redaction.redact("nothing sensitive here", ["sk-abc123"]) ==
               "nothing sensitive here"
    end
  end
end
