defmodule Arbiter.ProviderAccountsRuntimeConfigTest do
  @moduledoc """
  bd-1zceei: `:provider_accounts_enabled` was only settable in the
  compile-time `config/config.exs`, which a release bakes in — so a release
  install could never turn it on. `config/runtime.exs` now reads
  `ARBITER_PROVIDER_ACCOUNTS` (the same variable `config/test.exs` already
  uses for the suite's flag-on leg) from the server's environment.
  """
  use ExUnit.Case, async: false

  @vars ~w(ARBITER_PROVIDER_ACCOUNTS SECRET_KEY_BASE)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {k, v} <- saved do
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end
    end)

    System.put_env("SECRET_KEY_BASE", saved["SECRET_KEY_BASE"] || "test-secret-key-base")
    :ok
  end

  defp read_flag(env) do
    "../../config/runtime.exs"
    |> Config.Reader.read!(env: env)
    |> get_in([:arbiter, :provider_accounts_enabled])
  end

  test "leaves the compile-time default alone when the variable is unset" do
    System.delete_env("ARBITER_PROVIDER_ACCOUNTS")
    assert read_flag(:prod) == nil
  end

  for value <- ["1", "true"] do
    test "ARBITER_PROVIDER_ACCOUNTS=#{value} turns the flag on in a release (prod)" do
      System.put_env("ARBITER_PROVIDER_ACCOUNTS", unquote(value))
      assert read_flag(:prod) == true
    end
  end

  for value <- ["0", "false"] do
    test "ARBITER_PROVIDER_ACCOUNTS=#{value} turns the flag off explicitly" do
      System.put_env("ARBITER_PROVIDER_ACCOUNTS", unquote(value))
      assert read_flag(:prod) == false
    end
  end

  test "an unrecognised value refuses to boot rather than guessing" do
    System.put_env("ARBITER_PROVIDER_ACCOUNTS", "yes please")

    assert_raise RuntimeError, ~r/ARBITER_PROVIDER_ACCOUNTS/, fn -> read_flag(:prod) end
  end

  test "applies to a dev (source) server too" do
    System.put_env("ARBITER_PROVIDER_ACCOUNTS", "1")
    assert read_flag(:dev) == true
  end

  test "never overrides the test suite's own switch in config/test.exs" do
    System.put_env("ARBITER_PROVIDER_ACCOUNTS", "1")
    assert read_flag(:test) == nil
  end
end
