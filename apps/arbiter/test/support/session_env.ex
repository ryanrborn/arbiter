defmodule Arbiter.Test.SessionEnv do
  @moduledoc """
  Point the session roots at throwaway tmp dirs for one test (bd-aprlbb).

  Exists because the obvious spelling is wrong in a way that only shows up in
  *another* test file: `Application.put_env/3` in `setup` plus
  `Application.delete_env/2` in `on_exit` does not restore the value
  `config/test.exs` set — it **deletes** it, so every later test in the same VM
  falls through to the `$HOME`-relative default and provisions a session into
  the operator's real `~/dev/arbiter-sessions`. Save-and-restore, always.
  """

  @keys [
    :sessions_root,
    :sessions_runtime_dir,
    :primary_checkout,
    :sessions_credentials_source,
    :sessions_agent_command,
    :sessions_launch_command
  ]

  @doc """
  Override the given `:arbiter` keys for this test, restoring the previous
  values (including "was unset") on exit. Returns the overrides, so a `setup`
  block can hand them straight to the test context.
  """
  @spec override(keyword()) :: keyword()
  def override(overrides) do
    previous = Enum.map(@keys, &{&1, Application.fetch_env(:arbiter, &1)})

    Enum.each(overrides, fn {key, value} ->
      true = key in @keys
      Application.put_env(:arbiter, key, value)
    end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbiter, key, value)
        {key, :error} -> Application.delete_env(:arbiter, key)
      end)
    end)

    overrides
  end

  @doc """
  A full set of unique tmp roots for a session test — `:sessions_root`,
  `:sessions_runtime_dir`, `:primary_checkout` and
  `:sessions_credentials_source` — all removed on exit.
  """
  @spec sandbox(String.t()) :: keyword()
  def sandbox(tag) do
    unique = "#{tag}-#{System.unique_integer([:positive])}"
    base = Path.join(System.tmp_dir!(), "arbiter-session-test-#{unique}")

    overrides = [
      sessions_root: Path.join(base, "sessions"),
      sessions_runtime_dir: Path.join(base, "runtime"),
      primary_checkout: Path.join(base, "checkout"),
      sessions_credentials_source: Path.join(base, "operator")
    ]

    File.mkdir_p!(overrides[:primary_checkout])
    File.mkdir_p!(overrides[:sessions_credentials_source])
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(base) end)

    override(overrides)
  end
end
