defmodule Arbiter.Boot.MigratorTest do
  # The skip path and the child spec are pure — no DB / sandbox involved. We do
  # not exercise the primary (migrating) path here: it would run real
  # migrations against the shared test database, which `ash.setup` already
  # brings to head before the suite. The single-instance gate is what this
  # module owns and is what we assert.
  use ExUnit.Case, async: true

  alias Arbiter.Boot.Migrator

  describe "child_spec/1" do
    test "is a one-shot temporary worker with this module's id" do
      spec = Migrator.child_spec([])

      assert spec.id == Arbiter.Boot.Migrator
      assert spec.restart == :temporary
      assert spec.type == :worker
      assert {Arbiter.Boot.Migrator, :start_link, [[]]} = spec.start
    end

    test "is a blocking child, not a Task — so migrations finish before anything serves" do
      # bd-bksulf: `arb server deploy` no longer evals Arbiter.Release.migrate
      # against the still-running old server. It relies on this child instead:
      # a supervisor starts each child by *calling* its start function and
      # waiting, so a synchronous worker here blocks Arbiter.Application.start/2
      # until the schema is at head — and `:arbiter_web` (which depends on
      # `:arbiter`) only starts, and only binds the endpoint's port, after that
      # returns. A `Task` child would merely be spawned, letting the endpoint
      # serve against a half-migrated schema.
      spec = Migrator.child_spec([])

      assert {module, :start_link, _args} = spec.start
      refute module == Task
      assert spec.type == :worker
    end
  end

  describe "start_link/1 gating" do
    test "skips migrations and returns :ignore when not the primary instance" do
      # A SECONDARY boot must never migrate. With `primary?: false` the migrate!
      # path is not taken at all, so this needs no database connection — if it
      # did touch the DB this pure/async test would fail.
      assert Migrator.start_link(primary?: false) == :ignore
    end
  end
end
