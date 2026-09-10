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

  # Stub `agy_usage_probe` so tests never shell out to a real `agy` binary
  # that may happen to be installed on the machine running the suite.
  defp antigravity_opts(probe_result) do
    [agy_usage_probe: fn -> probe_result end]
  end

  defp agy_usage_body(groups) do
    %{"command" => %{"data" => %{"groups" => groups}}}
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

  describe "antigravity/1 (bd-d7hmqn: agy --output-format json --print /usage)" do
    test "flattens both groups and both windows into per-{group,window} model rows" do
      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.4, "reset_time" => "1782250684"},
              %{"window" => "5h", "remaining_fraction" => 0.75, "reset_time" => "1782250684"}
            ]
          },
          %{
            "name" => "Claude and GPT models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 1.0, "reset_time" => "1782250684"},
              %{"window" => "5h", "remaining_fraction" => 1.0, "reset_time" => "1782250684"}
            ]
          }
        ])

      snap = CloudCode.antigravity(antigravity_opts({:ok, body}))

      assert snap.provider == "antigravity"
      assert snap.message == nil
      assert length(snap.models) == 4

      by_id = Map.new(snap.models, &{&1.model_id, &1})
      gemini_weekly = by_id["gemini_models_weekly"]
      assert gemini_weekly.remaining_percentage == 40.0
      assert gemini_weekly.display_name == "Gemini Models (weekly)"
      assert gemini_weekly.reset_at == "2026-06-23T21:38:04.000Z"

      gemini_5h = by_id["gemini_models_5h"]
      assert gemini_5h.remaining_percentage == 75.0

      claude_weekly = by_id["claude_and_gpt_models_weekly"]
      assert claude_weekly.remaining_percentage == 100.0
      claude_5h = by_id["claude_and_gpt_models_5h"]
      assert claude_5h.remaining_percentage == 100.0
    end

    test "does not invert remaining_fraction — a nearly-empty bucket stays low, not high" do
      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [%{"window" => "5h", "remaining_fraction" => 0.02, "reset_time" => nil}]
          }
        ])

      snap = CloudCode.antigravity(antigravity_opts({:ok, body}))
      assert [model] = snap.models
      assert model.remaining_percentage == 2.0
      assert model.used == 980
    end

    test "degrades to a clear message when the agy binary is not on PATH" do
      snap =
        CloudCode.antigravity(agy_cmd: "definitely-not-a-real-agy-binary-xyz-#{__ENV__.line}")

      refute is_nil(snap)
      assert snap.provider == "antigravity"
      assert snap.models == []
      assert snap.message =~ "not installed"
    end

    test "degrades to a clear message when agy exits non-zero (not authenticated)" do
      snap = CloudCode.antigravity(antigravity_opts({:error, {:exit, 1}}))

      assert snap.models == []
      assert snap.message =~ "not authenticated"
    end

    test "degrades to a clear message on a subprocess timeout" do
      snap = CloudCode.antigravity(antigravity_opts({:error, :timeout}))

      assert snap.models == []
      assert snap.message =~ "did not respond in time"
    end

    test "degrades to a clear message on malformed JSON" do
      snap = CloudCode.antigravity(antigravity_opts({:error, :malformed}))

      assert snap.models == []
      assert snap.message =~ "unexpected data"
    end

    test "degrades to a clear message when the decoded JSON has no usage groups" do
      snap = CloudCode.antigravity(antigravity_opts({:ok, %{"command" => %{}}}))

      assert snap.models == []
      assert snap.message =~ "unexpected data"
    end

    test "never returns nil, unlike the old stored-token probe" do
      for result <- [
            {:ok, agy_usage_body([])},
            {:error, :not_installed},
            {:error, :timeout},
            {:error, {:exit, 1}},
            {:error, :malformed}
          ] do
        refute is_nil(CloudCode.antigravity(antigravity_opts(result)))
      end
    end
  end

  describe "antigravity/1 real shell-out path (agy_cmd, no agy_usage_probe stub)" do
    # These exercise `agy_usage_default/1` / `shell_out_agy_usage/2` for real —
    # `agy_cmd` points at a real executable instead of stubbing
    # `agy_usage_probe`, so the `System.find_executable/1` resolution, the
    # `sh -c` argv construction, and the exit-status / output-file handling
    # all actually run.
    test "a 0-exit executable with no parseable output degrades to the malformed-JSON message" do
      snap = CloudCode.antigravity(agy_cmd: "true")

      refute is_nil(snap)
      assert snap.message =~ "unexpected data"
    end

    test "a nonzero-exit executable is reported as not authenticated" do
      snap = CloudCode.antigravity(agy_cmd: "false")

      assert snap.models == []
      assert snap.message =~ "not authenticated"
    end

    test "an executable name that does not resolve is reported as not installed" do
      snap = CloudCode.antigravity(agy_cmd: "definitely-not-a-real-agy-binary-xyz")

      assert snap.models == []
      assert snap.message =~ "not installed"
    end

    test "the real subprocess result is memoized so repeated calls don't re-exec agy" do
      dir = System.tmp_dir!()
      script = Path.join(dir, "agy_counter_#{System.unique_integer([:positive])}.sh")
      counter = script <> ".count"

      File.write!(script, """
      #!/bin/sh
      echo x >> "#{counter}"
      echo '{"command":{"data":{"groups":[]}}}'
      exit 0
      """)

      File.chmod!(script, 0o755)

      on_exit(fn ->
        File.rm(script)
        File.rm(counter)
      end)

      opts = [agy_cmd: script]

      refute is_nil(CloudCode.antigravity(opts))
      refute is_nil(CloudCode.antigravity(opts))

      {:ok, contents} = File.read(counter)
      assert String.trim(contents) |> String.split("\n") |> length() == 1
    end
  end
end
