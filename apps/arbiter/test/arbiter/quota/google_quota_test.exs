defmodule Arbiter.Quota.GoogleQuotaTest do
  @moduledoc """
  Persistence + read-path tests for the Gemini CLI / Antigravity quota snapshots
  (bd-ajh7bd). Unlike `Arbiter.Quota.CloudCodeTest` (which is a pure, DB-less
  test of the live HTTP fetch), these exercise `CloudCode.refresh/3` upserting a
  `GoogleQuota` row and the DB read-back accessors, so they use `DataCase`.
  """
  use Arbiter.DataCase, async: false

  import Ecto.Query

  alias Arbiter.Quota.CloudCode
  alias Arbiter.Quota.GoogleQuota
  alias Arbiter.Tasks.Workspace

  @stub Arbiter.Quota.GoogleQuotaTest.HTTP

  defp workspace!(name \\ "default"), do: Ash.create!(Workspace, %{name: name})

  defp creds_file(token) do
    path =
      Path.join(System.tmp_dir!(), "gq_creds_#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{"access_token" => token}))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp opts(creds_path, extra) do
    Keyword.merge([creds_path: creds_path, plug: {Req.Test, @stub}], extra)
  end

  # Antigravity (bd-d7hmqn) no longer fetches over HTTP — it shells out to
  # the `agy` CLI — so its tests stub `agy_usage_probe` instead of `plug`.
  defp antigravity_opts(probe_result), do: [agy_usage_probe: fn -> probe_result end]

  defp agy_usage_body(groups), do: %{"command" => %{"data" => %{"groups" => groups}}}

  describe "refresh/3 (gemini)" do
    test "fetches live, upserts a GoogleQuota row, and returns the snapshot" do
      ws = workspace!()
      creds = creds_file("gemtoken")

      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "buckets" => [
            %{
              "modelId" => "gemini-2.5-pro",
              "remainingFraction" => 0.25,
              "resetTime" => "1782250684"
            },
            %{"modelId" => "gemini-2.5-flash", "remainingFraction" => 0.9, "resetTime" => nil}
          ]
        })
      end)

      snap = CloudCode.refresh(ws.id, :gemini, opts(creds, project_id: "p"))

      assert snap.provider == "gemini-cli"
      assert length(snap.models) == 2

      # The row persisted under the UI-facing provider code.
      row = CloudCode.latest(quota_account_id!(ws.id, "gemini_cli"), "gemini_cli")
      assert %GoogleQuota{} = row
      assert row.provider == "gemini_cli"
      assert row.plan == "Free"
      # Representative = the worst (most-used) important model: pro at 25% remaining
      # → 75% used.
      assert row.used_percent == 75.0
      assert %DateTime{} = row.captured_at
    end

    test "serialize_latest/2 reconstructs the per-model snapshot from the DB" do
      ws = workspace!()
      creds = creds_file("gemtoken")

      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "buckets" => [
            %{
              "modelId" => "gemini-2.5-pro",
              "remainingFraction" => 0.5,
              "resetTime" => "1782250684"
            }
          ]
        })
      end)

      assert CloudCode.refresh(ws.id, :gemini, opts(creds, project_id: "p"))

      serialized =
        CloudCode.serialize_latest(quota_account_id!(ws.id, "gemini_cli"), "gemini_cli")

      assert serialized["provider"] in ["gemini-cli", "gemini_cli"]
      assert [model] = serialized["models"]
      assert model["model_id"] == "gemini-2.5-pro"
      assert model["remaining_percentage"] == 50.0
    end

    test "returns nil and writes no row when credentials are absent" do
      ws = workspace!()
      missing = Path.join(System.tmp_dir!(), "absent_#{System.unique_integer([:positive])}.json")

      assert CloudCode.refresh(ws.id, :gemini, creds_path: missing, plug: {Req.Test, @stub}) ==
               nil

      assert CloudCode.latest(quota_account_id!(ws.id, "gemini_cli"), "gemini_cli") == nil
    end
  end

  describe "refresh/3 (antigravity)" do
    test "persists under the antigravity provider code" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.25, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))

      row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")
      assert %GoogleQuota{provider: "antigravity", used_percent: 75.0} = row
    end

    test "a subsequent degraded fetch (no model data) preserves the last good used_percent/reset_at/snapshot" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.25, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))
      good_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")
      assert good_row.used_percent == 75.0
      refute is_nil(good_row.reset_at)

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:error, {:exit, 1}}))
      degraded_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")

      assert degraded_row.used_percent == good_row.used_percent
      assert degraded_row.reset_at == good_row.reset_at
      assert degraded_row.message =~ "not authenticated"

      # The stored `snapshot` column (what `arb quota`/the MCP tool read back
      # verbatim via `serialize_latest/2`) must carry the *new* degraded
      # message, not the stale good-row copy — only the numeric figures
      # (used_percent/reset_at, asserted above) are preserved.
      assert degraded_row.snapshot["message"] == degraded_row.message

      assert CloudCode.serialize_latest(quota_account_id!(ws.id, "antigravity"), "antigravity")[
               "message"
             ] == degraded_row.message
    end

    test "a degraded fetch that preserves last-good figures also keeps the prior captured_at" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.25, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))
      good_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")

      # Backdate the good row's `captured_at` so a later same-second refresh
      # can't accidentally pass this assertion by coincidence.
      backdated = DateTime.add(good_row.captured_at, -3_600, :second)

      {1, nil} =
        Arbiter.Repo.update_all(
          from(q in Arbiter.Quota.GoogleQuota, where: q.id == ^good_row.id),
          set: [captured_at: backdated]
        )

      # bd-au2xhz: a degraded fetch (e.g. a timeout) with no new model data
      # must not stamp `captured_at` with `utc_now()` — that would make stale
      # figures look freshly captured to the Gate/Providers page/`arb quota`.
      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:error, :timeout}))
      degraded_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")

      assert degraded_row.captured_at == backdated

      # The stored `snapshot` JSON's own `captured_at` copy — what
      # `serialize_latest/2` returns verbatim to `arb quota --json`,
      # `GET /api/quota` and the MCP quota tool — must agree with the row
      # column rather than being stamped with the failed attempt's `now`.
      assert degraded_row.snapshot["captured_at"] == good_row.snapshot["captured_at"]

      assert CloudCode.serialize_latest(quota_account_id!(ws.id, "antigravity"), "antigravity")[
               "captured_at"
             ] == good_row.snapshot["captured_at"]
    end
  end

  describe "view/1" do
    test "maps a stored row to the uniform two-window view shape" do
      ws = workspace!()
      creds = creds_file("gemtoken")

      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "buckets" => [
            %{
              "modelId" => "gemini-2.5-pro",
              "remainingFraction" => 0.25,
              "resetTime" => "1782250684"
            }
          ]
        })
      end)

      CloudCode.refresh(ws.id, :gemini, opts(creds, project_id: "p"))

      view =
        quota_account_id!(ws.id, "gemini_cli")
        |> CloudCode.latest("gemini_cli")
        |> CloudCode.view()

      assert view.provider == "gemini_cli"
      assert view.provider_account_id == quota_account_id!(ws.id, "gemini_cli")
      assert_in_delta view.utilization_5h, 0.75, 0.0001
      assert %DateTime{} = view.reset_5h_at
      assert view.utilization_7d == nil
      assert view.reset_7d_at == nil
      assert view.primary_label == "used"
      assert view.secondary_label == nil
    end

    test "splits an antigravity row's 5h + weekly windows from the gemini_models group" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "5h", "remaining_fraction" => 0.75, "reset_time" => "1782250684"},
              %{"window" => "weekly", "remaining_fraction" => 0.4, "reset_time" => "1782250684"}
            ]
          },
          %{
            "name" => "Claude and GPT models",
            "buckets" => [
              %{"window" => "5h", "remaining_fraction" => 1.0, "reset_time" => "1782250684"},
              %{"window" => "weekly", "remaining_fraction" => 1.0, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))

      view =
        quota_account_id!(ws.id, "antigravity")
        |> CloudCode.latest("antigravity")
        |> CloudCode.view()

      assert view.provider == "antigravity"
      assert_in_delta view.utilization_5h, 0.25, 0.0001
      assert %DateTime{} = view.reset_5h_at
      assert_in_delta view.utilization_7d, 0.60, 0.0001
      assert %DateTime{} = view.reset_7d_at
      assert view.primary_label == "5h"
      assert view.secondary_label == "weekly"
      assert length(view.models) == 4
    end

    test "falls back to the collapsed shape when the antigravity snapshot has no parseable buckets" do
      ws = workspace!()

      row =
        Ash.create!(Arbiter.Quota.GoogleQuota, %{
          provider_account_id: quota_account_id!(ws.id, "antigravity"),
          provider: "antigravity",
          used_percent: 42.0,
          reset_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(3600),
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second),
          snapshot: %{"provider" => "antigravity", "models" => []}
        })

      view = CloudCode.view(row)

      assert_in_delta view.utilization_5h, 0.42, 0.0001
      assert view.reset_5h_at == row.reset_at
      assert view.utilization_7d == nil
      assert view.reset_7d_at == nil
      assert view.primary_label == "used"
      assert view.secondary_label == nil
    end
  end
end
