defmodule Arbiter.Boot.ConfigMigratorTest do
  # Exercises the real `rig_paths` -> `repo_paths` data migration against the
  # sandboxed DB, so `async: false` (workspace reads are global).
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Boot.ConfigMigrator
  alias Arbiter.Tasks.Workspace

  defp create_ws!(name, config) do
    Ash.create!(Workspace, %{name: name, config: config})
  end

  defp reload!(ws), do: Ash.get!(Workspace, ws.id)

  describe "child_spec/1" do
    test "is a one-shot temporary worker with this module's id" do
      spec = ConfigMigrator.child_spec([])

      assert spec.id == Arbiter.Boot.ConfigMigrator
      assert spec.restart == :temporary
      assert spec.type == :worker
      assert {Arbiter.Boot.ConfigMigrator, :start_link, [[]]} = spec.start
    end
  end

  describe "migrate_rig_paths/1" do
    test "copies a legacy rig_paths map to repo_paths and drops the old key" do
      ws =
        create_ws!("legacy", %{
          "rig_paths" => %{
            "verus-specs" => %{"path" => "/srv/verus-specs", "target_branch" => "develop"},
            "tonic" => "/srv/tonic"
          }
        })

      assert [result] = ConfigMigrator.migrate_rig_paths()
      assert result.workspace == "legacy"
      assert result.status == :migrated
      assert result.repos == ["tonic", "verus-specs"]

      config = reload!(ws).config

      assert config["repo_paths"] == %{
               "verus-specs" => %{"path" => "/srv/verus-specs", "target_branch" => "develop"},
               "tonic" => "/srv/tonic"
             }

      refute Map.has_key?(config, "rig_paths")
    end

    test "is a no-op on a workspace that never carried rig_paths" do
      ws = create_ws!("modern", %{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      assert ConfigMigrator.migrate_rig_paths() == []
      assert reload!(ws).config == %{"repo_paths" => %{"tonic" => "/srv/tonic"}}
    end

    test "is idempotent — a second run finds nothing left to migrate" do
      create_ws!("legacy", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert [_] = ConfigMigrator.migrate_rig_paths()
      assert ConfigMigrator.migrate_rig_paths() == []
    end

    test "merges into an existing repo_paths, with repo_paths winning on collision" do
      ws =
        create_ws!("both", %{
          "rig_paths" => %{"tonic" => "/old/tonic", "specs" => "/srv/specs"},
          "repo_paths" => %{"tonic" => "/new/tonic"}
        })

      assert [result] = ConfigMigrator.migrate_rig_paths()
      assert result.status == :migrated

      config = reload!(ws).config
      assert config["repo_paths"] == %{"tonic" => "/new/tonic", "specs" => "/srv/specs"}
      refute Map.has_key?(config, "rig_paths")
    end

    test "apply?: false reports what would move without writing" do
      ws = create_ws!("dry", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert [result] = ConfigMigrator.migrate_rig_paths(apply?: false)
      assert result.status == :dry_run
      assert result.repos == ["tonic"]
      assert result.repo_paths == %{"tonic" => "/srv/tonic"}

      config = reload!(ws).config
      assert config["rig_paths"] == %{"tonic" => "/srv/tonic"}
      refute Map.has_key?(config, "repo_paths")
    end

    # bd-3pqzsa review: `repo_paths` is not validated anywhere (ValidateConfig
    # allows unknown keys), and an operator debugging the zero-repos symptom is
    # very likely to type `arb config set repo_paths /srv/foo`, which stores a
    # bare string. Merging that would raise inside a supervision-tree child and
    # the server would not boot at all.
    test "a non-map repo_paths is replaced rather than raising" do
      ws =
        create_ws!("malformed", %{
          "rig_paths" => %{"tonic" => "/srv/tonic"},
          "repo_paths" => "/srv/verus-specs"
        })

      log =
        capture_log(fn ->
          assert [result] = ConfigMigrator.migrate_rig_paths()
          assert result.status == :migrated
          assert result.repos == ["tonic"]
        end)

      assert log =~ "non-map repo_paths"

      config = reload!(ws).config
      assert config["repo_paths"] == %{"tonic" => "/srv/tonic"}
      refute Map.has_key?(config, "rig_paths")
    end

    test "a non-map repo_paths does not stop other workspaces from migrating" do
      bad = create_ws!("bad", %{"rig_paths" => %{"a" => "/srv/a"}, "repo_paths" => 42})
      good = create_ws!("good", %{"rig_paths" => %{"b" => "/srv/b"}})

      capture_log(fn ->
        assert results = ConfigMigrator.migrate_rig_paths()
        assert length(results) == 2
        assert Enum.all?(results, &(&1.status == :migrated))
      end)

      assert reload!(bad).config["repo_paths"] == %{"a" => "/srv/a"}
      assert reload!(good).config["repo_paths"] == %{"b" => "/srv/b"}
    end

    test "a non-map rig_paths is not a migration candidate at all" do
      ws = create_ws!("junk", %{"rig_paths" => "/srv/tonic"})

      assert ConfigMigrator.migrate_rig_paths() == []
      assert reload!(ws).config == %{"rig_paths" => "/srv/tonic"}
    end

    test "logs a warning naming the workspace and the repos it moved" do
      create_ws!("loud", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      log = capture_log(fn -> ConfigMigrator.migrate_rig_paths() end)

      assert log =~ "rig_paths"
      assert log =~ "repo_paths"
      assert log =~ "loud"
    end
  end

  describe "start_link/1" do
    test "migrates and returns :ignore on the primary instance" do
      ws = create_ws!("primary", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert ConfigMigrator.start_link(primary?: true) == :ignore
      assert reload!(ws).config["repo_paths"] == %{"tonic" => "/srv/tonic"}
    end

    # A raise here would fail Supervisor.start_link/2 and the server would not
    # boot at all — worse than the zero-repos bug this module exists to fix.
    test "a malformed workspace config never aborts the boot" do
      ws =
        create_ws!("malformed-boot", %{
          "rig_paths" => %{"tonic" => "/srv/tonic"},
          "repo_paths" => "/srv/tonic"
        })

      capture_log(fn -> assert ConfigMigrator.start_link(primary?: true) == :ignore end)

      assert reload!(ws).config["repo_paths"] == %{"tonic" => "/srv/tonic"}
    end

    test "skips entirely and returns :ignore when not the primary instance" do
      ws = create_ws!("secondary", %{"rig_paths" => %{"tonic" => "/srv/tonic"}})

      assert ConfigMigrator.start_link(primary?: false) == :ignore
      assert reload!(ws).config["rig_paths"] == %{"tonic" => "/srv/tonic"}
      refute Map.has_key?(reload!(ws).config, "repo_paths")
    end
  end
end
