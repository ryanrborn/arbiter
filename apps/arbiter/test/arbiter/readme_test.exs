defmodule Arbiter.ReadmeTest do
  use ExUnit.Case, async: true

  @readme Path.expand("../../../../README.md", __DIR__)

  @stale ~w(Admiral Acolyte Warship Directive)

  test "README does not use retired fleet vernacular" do
    contents = File.read!(@readme)

    for term <- @stale do
      refute contents =~ term,
             "README.md still references retired term #{inspect(term)} — use the standard term instead"
    end

    refute contents =~ "vernacular",
           "README.md still describes the removed per-workspace vernacular feature"
  end

  test "README documents the SQLite datastore, not Postgres/Docker" do
    contents = File.read!(@readme)

    assert contents =~ "SQLite"
    refute contents =~ "docker compose up"
    refute contents =~ "for the Postgres database"
  end
end
