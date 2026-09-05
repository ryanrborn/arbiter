defmodule Arbiter.Worker.RunProvenanceTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.RunProvenance

  describe "skills/1" do
    test "maps a resolved skill list to {name, activation_mode, skill_version} triples" do
      {:ok, skill} =
        Arbiter.Skills.create_skill(%{
          name: "prov-skill-#{System.unique_integer([:positive])}",
          body: "# Body",
          activation_mode: :always_on
        })

      resolved = [%{skill: skill, activation: :situational}]

      assert [entry] = RunProvenance.skills(resolved)
      assert entry["name"] == skill.name
      # The layered selection's per-dispatch override (:situational) wins over
      # the skill's own stored activation_mode (:always_on) — provenance must
      # record what actually governed the run, not the skill's default.
      assert entry["activation_mode"] == "situational"
      assert entry["skill_version"] == DateTime.to_iso8601(skill.updated_at)
    end

    test "empty for an empty resolved list" do
      assert RunProvenance.skills([]) == []
    end
  end

  describe "standing_orders_digest/1" do
    test "nil when the workspace has no standing_orders" do
      {:ok, ws} = Ash.create(Workspace, %{name: "prov-ws-#{uniq()}", prefix: "pv"})
      assert RunProvenance.standing_orders_digest(ws) == nil
    end

    test "nil when standing_orders is an empty list" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{"standing_orders" => []}
        })

      assert RunProvenance.standing_orders_digest(ws) == nil
    end

    test "a stable sha256 hex digest of the effective standing_orders text" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{"standing_orders" => ["always run tests", "never force-push"]}
        })

      digest = RunProvenance.standing_orders_digest(ws)
      assert is_binary(digest)
      assert String.length(digest) == 64
      assert digest =~ ~r/^[0-9a-f]{64}$/

      expected =
        :sha256
        |> :crypto.hash("always run tests\nnever force-push")
        |> Base.encode16(case: :lower)

      assert digest == expected
    end

    test "changes when the standing_orders text changes" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{"standing_orders" => ["a"]}
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{"standing_orders" => ["b"]}
        })

      refute RunProvenance.standing_orders_digest(ws1) ==
               RunProvenance.standing_orders_digest(ws2)
    end

    test "handles maps with title and detail (documented format)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{
            "standing_orders" => [
              %{"title" => "run tests", "detail" => "before commit"}
            ]
          }
        })

      digest = RunProvenance.standing_orders_digest(ws)
      assert is_binary(digest)
      assert String.length(digest) == 64
    end

    test "handles maps with title only" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{
            "standing_orders" => [
              %{"title" => "run tests"}
            ]
          }
        })

      digest = RunProvenance.standing_orders_digest(ws)
      assert is_binary(digest)
      assert String.length(digest) == 64
    end

    test "handles mixed lists of strings and maps" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{
            "standing_orders" => [
              "always run tests",
              %{"title" => "review code", "detail" => "before merge"},
              %{"title" => "check lint"},
              "never force-push"
            ]
          }
        })

      digest = RunProvenance.standing_orders_digest(ws)
      assert is_binary(digest)
      assert String.length(digest) == 64
    end

    test "hashes maps deterministically regardless of key order" do
      {:ok, ws1} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{
            "standing_orders" => [
              %{"title" => "run tests", "detail" => "before commit"}
            ]
          }
        })

      {:ok, ws2} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{
            "standing_orders" => [
              %{"detail" => "before commit", "title" => "run tests"}
            ]
          }
        })

      assert RunProvenance.standing_orders_digest(ws1) ==
               RunProvenance.standing_orders_digest(ws2)
    end
  end

  describe "routing_policy_string/1" do
    test "defaults to \"static\" for a workspace with no routing config" do
      {:ok, ws} = Ash.create(Workspace, %{name: "prov-ws-#{uniq()}", prefix: "pv"})
      assert RunProvenance.routing_policy_string(ws) == "static"
    end

    test "reflects a configured policy" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "prov-ws-#{uniq()}",
          prefix: "pv",
          config: %{"routing" => %{"policy" => "by_difficulty"}}
        })

      assert RunProvenance.routing_policy_string(ws) == "by_difficulty"
    end

    test "\"static\" for nil workspace" do
      assert RunProvenance.routing_policy_string(nil) == "static"
    end
  end

  defp uniq, do: System.unique_integer([:positive])
end
