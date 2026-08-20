defmodule Arbiter.TestDbPartition do
  @moduledoc false

  # bd-2xvwew: concurrent `mix test` invocations (e.g. one per Arbiter worker's
  # git worktree, all on the same host) previously shared a single hardcoded
  # sqlite path (System.tmp_dir!() is host-wide, not worktree-scoped). Each
  # invocation's `mix test` alias runs `ash.setup --quiet` first, so two
  # concurrent runs would migrate/recreate the same file out from under each
  # other — observed as `Exqlite.Error) no such table: workspaces` and
  # hundreds of unrelated test failures, not just DBConnection checkout
  # timeouts. Deriving the filename from `cwd` gives each worktree (and thus
  # each concurrently-dispatched worker) its own isolated database file with
  # no coordination required from the caller.
  def suffix(cwd \\ File.cwd!()) do
    cwd
    |> :erlang.phash2()
    |> Integer.to_string(36)
  end
end
