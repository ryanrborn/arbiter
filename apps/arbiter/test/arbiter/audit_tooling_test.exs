defmodule Arbiter.AuditToolingTest do
  @moduledoc """
  Guards the static-analysis / security-scanning toolchain (bd-4x2yhq).

  Arbiter shipped for a long time with no `credo`, `dialyxir` or `sobelow` at
  all, while the sibling codebases this coordinator manages ran all three
  behind a `mix audit` alias. These assertions keep the toolchain from being
  quietly dropped again: they pin the deps, the umbrella-wide dialyzer PLT
  layout, the alias contents, and the CI stage that runs it.

  They deliberately assert on the *source* files rather than on
  `Mix.Project.config/0` — the child apps' configs aren't loaded from the
  umbrella-root test run, and the CI workflow isn't a Mix construct at all.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)

  @apps ~w(arbiter arbiter_web arbiter_cli)

  defp read!(relative), do: File.read!(Path.join(@root, relative))

  describe "dependencies" do
    test "every umbrella app declares credo, dialyxir and sobelow" do
      for app <- @apps do
        mix_exs = read!("apps/#{app}/mix.exs")

        for dep <- ~w(credo dialyxir sobelow) do
          assert mix_exs =~ "{:#{dep},",
                 "apps/#{app}/mix.exs does not declare the :#{dep} dependency"
        end
      end
    end

    test "the umbrella root declares them too, so the tasks run from the root" do
      mix_exs = read!("mix.exs")

      for dep <- ~w(credo dialyxir sobelow) do
        assert mix_exs =~ "{:#{dep},",
               "root mix.exs does not declare :#{dep}; `mix #{dep}` from the umbrella root " <>
                 "would not resolve the task"
      end
    end

    test "the analysis deps never ship in a release" do
      for path <- ["mix.exs" | Enum.map(@apps, &"apps/#{&1}/mix.exs")] do
        source = read!(path)

        for dep <- ~w(credo dialyxir sobelow) do
          [line] =
            source
            |> String.split("\n")
            |> Enum.filter(&String.contains?(&1, "{:#{dep},"))

          assert line =~ "only: [:dev, :test]",
                 "#{path}: :#{dep} must be scoped `only: [:dev, :test]`"

          assert line =~ "runtime: false",
                 "#{path}: :#{dep} must be declared `runtime: false`"
        end
      end
    end
  end

  describe "credo configuration" do
    test ".credo.exs exists and runs in strict mode" do
      config = read!(".credo.exs")

      assert config =~ "strict: true",
             ".credo.exs must enable strict mode"
    end

    test ".credo.exs analyses every umbrella app" do
      config = read!(".credo.exs")

      assert config =~ "apps/*/lib/",
             ".credo.exs must include the umbrella apps' lib/ directories"
    end
  end

  describe "dialyzer configuration" do
    test "the umbrella root owns a single shared PLT" do
      mix_exs = read!("mix.exs")

      assert mix_exs =~ "dialyzer:",
             "root mix.exs must carry the umbrella-wide dialyzer config"

      assert mix_exs =~ "plt_core_path:",
             "root mix.exs must pin plt_core_path so the core PLT is shared, not rebuilt per app"

      assert mix_exs =~ "plt_local_path:",
             "root mix.exs must pin plt_local_path so all three apps analyse against one PLT"
    end

    test "child apps point at the same PLT directory as the root" do
      root_plt_dir = "priv/plts"

      assert read!("mix.exs") =~ root_plt_dir

      for app <- @apps do
        mix_exs = read!("apps/#{app}/mix.exs")

        assert mix_exs =~ "../../#{root_plt_dir}",
               "apps/#{app}/mix.exs must reuse the umbrella-root PLT at #{root_plt_dir}, " <>
                 "not build a third redundant one"
      end
    end

    test "the PLT directory is not committed" do
      assert read!(".gitignore") =~ "priv/plts"
    end
  end

  defp audit_alias_body do
    source = read!("mix.exs")

    [_, rest] = String.split(source, "audit: [", parts: 2)
    [body, _] = String.split(rest, "]", parts: 2)
    body
  end

  describe "mix audit alias" do
    test "runs format, compile-as-errors, credo --strict, sobelow and dialyzer" do
      alias_body = audit_alias_body()

      assert alias_body =~ "format --check-formatted"
      assert alias_body =~ "compile --warnings-as-errors"
      assert alias_body =~ "credo"
      assert alias_body =~ "--strict"
      assert alias_body =~ "sobelow"
      assert alias_body =~ "dialyzer"
    end

    test "is registered on the umbrella root project" do
      assert "audit" in Enum.map(Keyword.keys(Mix.Project.config()[:aliases] || []), &to_string/1) or
               read!("mix.exs") =~ "audit: [",
             "root mix.exs must define the `audit` alias"
    end

  end

  describe "CI" do
    test "a job runs mix audit on every pull request" do
      workflow = read!(".github/workflows/ci.yml")

      assert workflow =~ "mix audit",
             ".github/workflows/ci.yml must run the audit alias"
    end

    test "the audit job caches the dialyzer PLT" do
      workflow = read!(".github/workflows/ci.yml")

      assert workflow =~ "priv/plts",
             "the audit job must cache priv/plts — an uncached PLT rebuild costs minutes per run"
    end
  end
end
