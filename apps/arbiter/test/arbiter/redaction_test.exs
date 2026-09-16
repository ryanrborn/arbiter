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

  describe "redact_patterns/1" do
    test "redacts an Anthropic API key by shape, no registered secret needed" do
      assert Redaction.redact_patterns(
               "export ANTHROPIC_API_KEY=sk-ant-abcdefghijklmnopqrstuvwxyz"
             ) ==
               "export ANTHROPIC_API_KEY=[REDACTED]"
    end

    test "redacts a GitHub personal access token" do
      assert Redaction.redact_patterns("token: ghp_1234567890abcdefghijklmnopqrstuvwxyz") ==
               "token: [REDACTED]"
    end

    test "redacts an AWS access key id" do
      assert Redaction.redact_patterns("AKIAIOSFODNN7EXAMPLE") == "[REDACTED]"
    end

    test "redacts a bearer token header" do
      assert Redaction.redact_patterns("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345") ==
               "Authorization: [REDACTED]"
    end

    test "redacts a PEM private key block" do
      pem = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIEpAIBAAKCAQEA1234567890
      -----END RSA PRIVATE KEY-----
      """

      assert Redaction.redact_patterns(pem) == "[REDACTED]\n"
    end

    test "leaves ordinary text untouched" do
      assert Redaction.redact_patterns("nothing sensitive here") == "nothing sensitive here"
    end

    test "a non-binary input is returned unchanged" do
      assert Redaction.redact_patterns(nil) == nil
    end
  end
end
