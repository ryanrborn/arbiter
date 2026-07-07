defmodule Arbiter.Quota.GoogleQuotaTest do
  @moduledoc """
  Persistence + read-path tests for the Gemini CLI / Antigravity quota snapshots
  (bd-ajh7bd). Unlike `Arbiter.Quota.CloudCodeTest` (which is a pure, DB-less
  test of the live HTTP fetch), these exercise `CloudCode.refresh/3` upserting a
  `GoogleQuota` row and the DB read-back accessors, so they use `DataCase`.
  """
  use Arbiter.DataCase, async: false

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
      row = CloudCode.latest(ws.id, "gemini_cli")
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

      serialized = CloudCode.serialize_latest(ws.id, "gemini_cli")
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

      assert CloudCode.latest(ws.id, "gemini_cli") == nil
    end
  end

  describe "refresh/3 (antigravity)" do
    test "persists under the antigravity provider code" do
      ws = workspace!()
      creds = creds_file("agtoken")

      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "models" => %{
            "gemini-3-flash" => %{
              "displayName" => "Gemini 3 Flash",
              "quotaInfo" => %{"remainingFraction" => 0.25, "resetTime" => "1782250684"}
            }
          }
        })
      end)

      assert CloudCode.refresh(ws.id, :antigravity, opts(creds, project_id: "p"))

      row = CloudCode.latest(ws.id, "antigravity")
      assert %GoogleQuota{provider: "antigravity", used_percent: 75.0} = row
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
      view = ws.id |> CloudCode.latest("gemini_cli") |> CloudCode.view()

      assert view.provider == "gemini_cli"
      assert view.workspace_id == ws.id
      assert_in_delta view.utilization_5h, 0.75, 0.0001
      assert %DateTime{} = view.reset_5h_at
      assert view.utilization_7d == nil
    end
  end
end
