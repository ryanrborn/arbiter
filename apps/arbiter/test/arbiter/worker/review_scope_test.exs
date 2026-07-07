defmodule Arbiter.Worker.ReviewScopeTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewScope

  describe "normalize/1" do
    test "accepts atoms and strings" do
      assert ReviewScope.normalize(:diff) == :diff
      assert ReviewScope.normalize(:repo) == :repo
      assert ReviewScope.normalize("diff") == :diff
      assert ReviewScope.normalize("repo") == :repo
    end

    test "rejects anything else" do
      assert ReviewScope.normalize(nil) == nil
      assert ReviewScope.normalize("") == nil
      assert ReviewScope.normalize("bogus") == nil
    end
  end

  describe "glob_match?/2" do
    test "matches ** across directory segments" do
      assert ReviewScope.glob_match?("**/sigv4/**", "lib/verus/sigv4/signer.ex")
      assert ReviewScope.glob_match?("**/*auth*", "lib/verus_auth_server/session.ex")
      assert ReviewScope.glob_match?("kickstart*.json", "kickstart.prod.json")
      assert ReviewScope.glob_match?("**/tasks/*.ex", "lib/arbiter/tasks/issue.ex")
    end

    test "does not match unrelated paths" do
      refute ReviewScope.glob_match?("**/sigv4/**", "lib/verus/http/client.ex")
      refute ReviewScope.glob_match?("kickstart*.json", "config/other.json")
    end
  end

  describe "resolve/3" do
    test "an explicit override always wins" do
      assert ReviewScope.resolve(nil, "repo", ["lib/foo.ex"]) == :repo
      assert ReviewScope.resolve(%{}, :diff, ["kickstart.json"]) == :diff
    end

    test "escalates to :repo when a changed file matches a sensitive glob" do
      config = %{"review_scope" => %{"sensitive_globs" => ["**/sigv4/**"]}}
      assert ReviewScope.resolve(config, nil, ["lib/verus/sigv4/signer.ex"]) == :repo
    end

    test "falls back to the configured default when nothing matches" do
      config = %{"review_scope" => %{"default" => "repo", "sensitive_globs" => ["**/sigv4/**"]}}
      assert ReviewScope.resolve(config, nil, ["lib/other.ex"]) == :repo
    end

    test "falls back to :diff with no config" do
      assert ReviewScope.resolve(nil, nil, ["lib/foo.ex"]) == :diff
    end
  end
end
