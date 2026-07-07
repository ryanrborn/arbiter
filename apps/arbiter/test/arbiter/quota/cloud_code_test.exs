defmodule Arbiter.Quota.CloudCodeTest do
  # async: true — each test owns its own Req.Test stub and its own creds
  # tempfile, so there is no shared mutable state to race on.
  use ExUnit.Case, async: true

  alias Arbiter.Quota.CloudCode

  @stub Arbiter.Quota.CloudCodeTest.HTTP

  # Write a throwaway oauth_creds.json and return its path.
  defp creds_file(token) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "cc_creds_#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "access_token" => token,
        "refresh_token" => "r",
        "expiry_date" => 1_782_250_684_420,
        "token_type" => "Bearer"
      })
    )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp opts(creds_path, extra \\ []) do
    Keyword.merge([creds_path: creds_path, plug: {Req.Test, @stub}], extra)
  end

  # A path guaranteed not to exist — used as the default `creds_path` /
  # `antigravity_state_path` in antigravity tests so a test can never fall
  # through to reading the real user's live credentials off this machine.
  defp missing_path(suffix) do
    Path.join(System.tmp_dir!(), "nope_#{System.unique_integer([:positive])}#{suffix}")
  end

  defp antigravity_opts(extra) do
    Keyword.merge(
      [
        antigravity_state_path: missing_path(".vscdb"),
        creds_path: missing_path(".json"),
        plug: {Req.Test, @stub}
      ],
      extra
    )
  end

  # Write a throwaway Antigravity `state.vscdb` (the VS Code globalStorage
  # sqlite DB Antigravity itself writes on every OAuth refresh) containing an
  # `antigravityAuthStatus` row with the given apiKey, and return its path.
  defp antigravity_state_file(api_key) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "ag_state_#{System.unique_integer([:positive])}.vscdb")

    {:ok, db} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(
        db,
        "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"
      )

    value =
      Jason.encode!(%{"apiKey" => api_key, "name" => "Test User", "email" => "t@example.com"})

    {:ok, stmt} = Exqlite.Sqlite3.prepare(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?)")
    :ok = Exqlite.Sqlite3.bind(stmt, ["antigravityAuthStatus", value])
    :done = Exqlite.Sqlite3.step(db, stmt)
    :ok = Exqlite.Sqlite3.close(db)

    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "gemini/1 credential handling" do
    test "returns nil when the creds file is absent (graceful no-op)" do
      missing =
        Path.join(System.tmp_dir!(), "does_not_exist_#{System.unique_integer([:positive])}.json")

      assert CloudCode.gemini(creds_path: missing) == nil
    end

    test "returns nil when the creds file has no access_token" do
      dir = System.tmp_dir!()
      path = Path.join(dir, "cc_empty_#{System.unique_integer([:positive])}.json")
      File.write!(path, Jason.encode!(%{"refresh_token" => "r"}))
      on_exit(fn -> File.rm(path) end)

      assert CloudCode.gemini(creds_path: path) == nil
    end
  end

  describe "gemini/1 quota fetch" do
    test "resolves the project via loadCodeAssist then returns per-model buckets" do
      creds = creds_file("gemtoken")

      Req.Test.stub(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert ["Bearer gemtoken"] = Plug.Conn.get_req_header(conn, "authorization")

        cond do
          String.ends_with?(conn.request_path, "loadCodeAssist") ->
            assert Map.has_key?(decoded, "metadata")

            Req.Test.json(conn, %{
              "cloudaicompanionProject" => "proj-abc",
              "currentTier" => %{"name" => "Standard"}
            })

          String.ends_with?(conn.request_path, "retrieveUserQuota") ->
            assert decoded == %{"project" => "proj-abc"}

            Req.Test.json(conn, %{
              "buckets" => [
                %{
                  "modelId" => "gemini-2.5-pro",
                  "remainingFraction" => 0.5,
                  "resetTime" => "1782250684"
                },
                %{"modelId" => "gemini-2.5-flash", "remainingFraction" => 1.0, "resetTime" => nil}
              ]
            })
        end
      end)

      snap = CloudCode.gemini(opts(creds))

      assert snap.provider == "gemini-cli"
      assert snap.plan == "Standard"
      assert snap.message == nil
      assert is_binary(snap.captured_at)

      by_id = Map.new(snap.models, &{&1.model_id, &1})

      pro = by_id["gemini-2.5-pro"]
      assert pro.total == 1000
      assert pro.used == 500
      assert pro.remaining_percentage == 50.0
      assert pro.unlimited == false
      assert pro.reset_at == "2026-06-23T21:38:04.000Z"

      flash = by_id["gemini-2.5-flash"]
      assert flash.used == 0
      assert flash.remaining_percentage == 100.0
      assert flash.reset_at == nil
    end

    test "uses an injected project_id and skips loadCodeAssist" do
      creds = creds_file("gemtoken")

      Req.Test.stub(@stub, fn conn ->
        assert String.ends_with?(conn.request_path, "retrieveUserQuota")
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"project" => "cached-proj"}
        Req.Test.json(conn, %{"buckets" => []})
      end)

      snap = CloudCode.gemini(opts(creds, project_id: "cached-proj"))
      assert snap.models == []
      assert snap.message == nil
    end

    test "returns a message (not a crash) on an expired token" do
      creds = creds_file("stale")

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "expired"})
      end)

      snap = CloudCode.gemini(opts(creds, project_id: "p"))
      assert snap.models == []
      assert snap.message =~ "auth"
    end

    test "reports missing project id when loadCodeAssist yields none" do
      creds = creds_file("gemtoken")

      Req.Test.stub(@stub, fn conn ->
        assert String.ends_with?(conn.request_path, "loadCodeAssist")
        Req.Test.json(conn, %{"currentTier" => %{"name" => "Free"}})
      end)

      snap = CloudCode.gemini(opts(creds))
      assert snap.models == []
      assert snap.plan == "Free"
      assert snap.message =~ "project"
    end
  end

  describe "antigravity/1 quota fetch" do
    test "sends antigravity headers and filters to important models" do
      state = antigravity_state_file("agtoken")

      Req.Test.stub(@stub, fn conn ->
        cond do
          String.ends_with?(conn.request_path, "loadCodeAssist") ->
            assert Plug.Conn.get_req_header(conn, "x-request-source") == ["local"]

            Req.Test.json(conn, %{
              "cloudaicompanionProject" => "ag-proj",
              "currentTier" => %{"name" => "Pro"}
            })

          String.ends_with?(conn.request_path, "fetchAvailableModels") ->
            assert Plug.Conn.get_req_header(conn, "x-client-name") == ["antigravity"]
            assert Plug.Conn.get_req_header(conn, "x-request-source") == ["local"]
            assert ["Bearer agtoken"] = Plug.Conn.get_req_header(conn, "authorization")
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(body) == %{"project" => "ag-proj"}

            Req.Test.json(conn, %{
              "models" => %{
                "gemini-3-flash" => %{
                  "displayName" => "Gemini 3 Flash",
                  "quotaInfo" => %{"remainingFraction" => 0.25, "resetTime" => "1782250684"}
                },
                "some-internal-model" => %{
                  "isInternal" => true,
                  "quotaInfo" => %{"remainingFraction" => 0.9}
                },
                "not-important-model" => %{
                  "quotaInfo" => %{"remainingFraction" => 0.9}
                }
              }
            })
        end
      end)

      snap = CloudCode.antigravity(antigravity_opts(antigravity_state_path: state))

      assert snap.provider == "antigravity"
      assert snap.plan == "Pro"
      assert [model] = snap.models
      assert model.model_id == "gemini-3-flash"
      assert model.display_name == "Gemini 3 Flash"
      assert model.used == 750
      assert model.remaining_percentage == 25.0
    end

    test "returns nil when neither the Antigravity state db nor the gemini creds fallback exist" do
      assert CloudCode.antigravity(antigravity_opts([])) == nil
    end

    test "reads its own token from the Antigravity state db, not the Gemini CLI creds file" do
      state = antigravity_state_file("antigravity-own-token")
      # A stale/different Gemini CLI token must never leak into the Antigravity request.
      gemini_creds = creds_file("stale-gemini-token")

      Req.Test.stub(@stub, fn conn ->
        assert ["Bearer antigravity-own-token"] =
                 Plug.Conn.get_req_header(conn, "authorization")

        Req.Test.json(conn, %{"models" => %{}})
      end)

      snap =
        CloudCode.antigravity(
          antigravity_state_path: state,
          creds_path: gemini_creds,
          project_id: "p",
          plug: {Req.Test, @stub}
        )

      assert snap.models == []
    end

    test "falls back to the Gemini CLI creds file when the Antigravity state db is absent" do
      missing_state =
        Path.join(System.tmp_dir!(), "nope_#{System.unique_integer([:positive])}.vscdb")

      gemini_creds = creds_file("fallback-token")

      Req.Test.stub(@stub, fn conn ->
        assert ["Bearer fallback-token"] = Plug.Conn.get_req_header(conn, "authorization")
        Req.Test.json(conn, %{"models" => %{}})
      end)

      snap =
        CloudCode.antigravity(
          antigravity_state_path: missing_state,
          creds_path: gemini_creds,
          project_id: "p",
          plug: {Req.Test, @stub}
        )

      assert snap.models == []
    end

    test "degrades to a message on a 403" do
      state = antigravity_state_file("agtoken")

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "forbidden"})
      end)

      snap = CloudCode.antigravity(antigravity_opts(antigravity_state_path: state))

      assert snap.models == []
      assert is_binary(snap.message)
    end
  end
end
