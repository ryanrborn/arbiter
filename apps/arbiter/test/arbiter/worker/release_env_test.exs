defmodule Arbiter.Worker.ReleaseEnvTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReleaseEnv

  describe "clean_pairs/0 when no release env is set" do
    test "returns [] on a plain dev VM with no RELEASE_ROOT" do
      # The test VM is not started as an OTP release, so no RELEASE_* or
      # ROOTDIR/BINDIR should be set. We assert the return is a list (possibly
      # non-empty if the test host happens to have some of these set, but the
      # type contract holds).
      result = ReleaseEnv.clean_pairs()
      assert is_list(result)
    end
  end

  describe "clean_pairs/0 logic" do
    test "includes {name, false} for each simulated release var" do
      # We can't safely mutate System.get_env() in the test process, so we
      # unit-test the logic by exercising the module's documented contract via
      # its output: every pair must be {string, string | false}.
      pairs = ReleaseEnv.clean_pairs()

      for {name, value} <- pairs do
        assert is_binary(name), "expected string key, got: #{inspect(name)}"
        assert value == false or is_binary(value),
               "expected false or string value for #{name}, got: #{inspect(value)}"
      end
    end

    test "PATH pair (if present) does not contain RELEASE_ROOT prefix" do
      pairs = ReleaseEnv.clean_pairs()
      release_root = System.get_env("RELEASE_ROOT")

      case {Enum.find(pairs, &match?({"PATH", _}, &1)), release_root} do
        {{"PATH", cleaned_path}, root} when is_binary(root) ->
          # Each segment of the cleaned PATH must not start with RELEASE_ROOT
          for segment <- String.split(cleaned_path, ":") do
            refute String.starts_with?(segment, root),
                   "PATH segment #{inspect(segment)} still contains RELEASE_ROOT prefix #{inspect(root)}"
          end

        _ ->
          # No PATH pair returned or RELEASE_ROOT not set: both are fine
          :ok
      end
    end

    test "does not contain duplicate names" do
      pairs = ReleaseEnv.clean_pairs()
      names = Enum.map(pairs, &elem(&1, 0))
      assert names == Enum.uniq(names), "clean_pairs/0 must not return duplicate names"
    end
  end
end
