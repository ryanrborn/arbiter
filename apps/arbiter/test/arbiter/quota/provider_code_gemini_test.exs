defmodule Arbiter.Quota.ProviderCodeGeminiTest do
  @moduledoc """
  `Arbiter.Quota.provider_code/1` for the `"gemini"` agent type must resolve
  the quota code matching the executable that will actually run (bd-7qj58o):
  `"antigravity"` when `agy` resolves, `"gemini_cli"` when the upstream CLI
  resolves — reusing `Arbiter.Agents.Gemini.resolve_executable/0` rather than
  a second, drift-prone PATH probe.

  Before this fix `provider_code("gemini")` was a static map lookup that
  always returned `"gemini_cli"`, so a fleet dispatching through `agy` was
  gated against a Google Cloud Code row that agy never writes — an
  `antigravity` row — while the dead `gemini_cli` row (never refreshed once
  `agy` is preferred) silently fails open.

  PATH is pinned to a stub directory (async: false, mirrors the existing
  pattern in `gemini_test.exs`) so these specs are deterministic regardless
  of whether the host actually has `agy` installed.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Quota

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "arbiter-provider-code-gemini-stub-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    old_path = System.get_env("PATH") || ""

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, old_path: old_path}
  end

  defp stub!(tmp, name) do
    path = Path.join(tmp, name)
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, 0o755)
  end

  test "resolves to \"antigravity\" when agy is on PATH", %{tmp: tmp} do
    stub!(tmp, "agy")
    stub!(tmp, "gemini")
    System.put_env("PATH", tmp)

    assert Quota.provider_code("gemini") == "antigravity"
    assert Quota.provider_code(:gemini) == "antigravity"
  end

  test "resolves to \"gemini_cli\" when only the upstream gemini CLI is on PATH", %{tmp: tmp} do
    stub!(tmp, "gemini")
    System.put_env("PATH", tmp)

    assert Quota.provider_code("gemini") == "gemini_cli"
    assert Quota.provider_code(:gemini) == "gemini_cli"
  end

  test "falls back to \"gemini_cli\" when neither binary is on PATH" do
    System.put_env("PATH", "/nonexistent-dir-for-test")

    assert Quota.provider_code("gemini") == "gemini_cli"
  end

  test "explicit \"gemini_cli\" / \"antigravity\" codes are never resolved dynamically", %{
    tmp: tmp
  } do
    stub!(tmp, "agy")
    System.put_env("PATH", tmp)

    # A caller that already names the concrete quota code gets it verbatim,
    # regardless of what's on PATH right now.
    assert Quota.provider_code("gemini_cli") == "gemini_cli"
    assert Quota.provider_code("antigravity") == "antigravity"
  end
end
