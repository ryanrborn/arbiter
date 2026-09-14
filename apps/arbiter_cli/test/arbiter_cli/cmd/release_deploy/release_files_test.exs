defmodule ArbiterCli.Cmd.ReleaseDeploy.ReleaseFilesTest do
  @moduledoc """
  Migration-set introspection over an unpacked OTP release tree (bd-bksulf).

  `arb server deploy` needs to know, *before* it swaps the `current` symlink,
  whether the release it is about to deploy carries migrations the release it
  would roll back to has never seen — because rolling back across one leaves
  old code on a newer schema.
  """
  use ExUnit.Case, async: true

  alias ArbiterCli.Cmd.ReleaseDeploy.ReleaseFiles

  # Build an unpacked-release-shaped dir with the given migration basenames in
  # the standard mix-release location (`lib/<app>-<vsn>/priv/repo/migrations`).
  defp release_dir(tag, migrations) do
    dir =
      Path.join(System.tmp_dir!(), "relfiles-#{tag}-#{System.unique_integer([:positive])}")

    migrations_dir =
      Path.join(dir, "lib/arbiter-#{String.trim_leading(tag, "v")}/priv/repo/migrations")

    File.mkdir_p!(migrations_dir)

    Enum.each(migrations, fn name ->
      File.write!(Path.join(migrations_dir, name <> ".exs"), "defmodule X do end")
    end)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "migrations/1" do
    test "maps each packaged migration's version to its name" do
      dir =
        release_dir("v2.0.0", [
          "20260101000000_create_things",
          "20260202000000_add_flag_to_things"
        ])

      assert ReleaseFiles.migrations(dir) == %{
               "20260101000000" => "20260101000000_create_things",
               "20260202000000" => "20260202000000_add_flag_to_things"
             }
    end

    test "is empty for a release tree with no packaged migrations" do
      dir = release_dir("v2.0.0", [])
      assert ReleaseFiles.migrations(dir) == %{}
    end

    test "is empty for nil (no prior release) and for an absent directory" do
      assert ReleaseFiles.migrations(nil) == %{}
      assert ReleaseFiles.migrations("/nonexistent/release/tree") == %{}
    end
  end

  describe "crossed_migrations/2" do
    test "names the migrations present in the new release but not the prior one" do
      prior = release_dir("v1.0.0", ["20260101000000_create_things"])

      new =
        release_dir("v2.0.0", [
          "20260101000000_create_things",
          "20260202000000_add_flag_to_things",
          "20260303000000_drop_legacy"
        ])

      assert ReleaseFiles.crossed_migrations(new, prior) == [
               "20260202000000_add_flag_to_things",
               "20260303000000_drop_legacy"
             ]
    end

    test "is empty when both releases carry the identical migration set" do
      migrations = ["20260101000000_create_things", "20260202000000_add_flag_to_things"]
      prior = release_dir("v1.0.0", migrations)
      new = release_dir("v2.0.0", migrations)

      assert ReleaseFiles.crossed_migrations(new, prior) == []
    end

    test "is empty when the new release only *drops* migration files" do
      # Nothing new landed in the DB, so a rollback is schema-safe.
      prior =
        release_dir("v1.0.0", ["20260101000000_create_things", "20260202000000_add_flag"])

      new = release_dir("v2.0.0", ["20260101000000_create_things"])

      assert ReleaseFiles.crossed_migrations(new, prior) == []
    end

    test "is empty when there is no prior release to compare against" do
      new = release_dir("v2.0.0", ["20260101000000_create_things"])
      assert ReleaseFiles.crossed_migrations(new, nil) == []
    end
  end
end
