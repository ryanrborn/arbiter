defmodule ArbiterWeb.Api.ExternalReviewControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Reviews.Record

  @ws "ws-external-review-test"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp insert_record!(attrs) do
    base = %{
      pr_ref: "github:owner/repo##{System.unique_integer([:positive])}",
      workspace_id: @ws,
      strategy: "github",
      status: :completed,
      started_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    }

    {:ok, rec} = Ash.create(Record, Map.merge(base, attrs))
    rec
  end

  describe "GET /api/external_reviews" do
    test "returns valid JSON with control characters in findings_summary properly escaped", %{
      conn: conn
    } do
      # Create a record with a multi-line findings_summary (containing literal newlines)
      # that will be embedded in JSON
      _rec =
        insert_record!(%{
          finding_count: 2,
          findings_summary:
            "[info] file.ex:10 — first finding\n[error] file.ex:20 — second finding"
        })

      conn = get(conn, ~p"/api/external_reviews", %{workspace_id: @ws})

      # The response status should be 200
      assert conn.status == 200

      # Get the raw response body as a string
      response_body = conn.resp_body

      # It must be valid JSON parseable with strict parsers (jq, json.load, Jason.decode!)
      # This will fail if control characters are not properly escaped
      {:ok, _parsed} = Jason.decode(response_body)

      # Also verify the JSON data contains properly escaped newlines
      {:ok, parsed} = Jason.decode(response_body)
      [record] = parsed["data"]

      # The findings_summary should have the literal newlines from the database
      # but they should be represented as escaped sequences in the JSON string
      assert record["findings_summary"] =~ "first finding"
      assert record["findings_summary"] =~ "second finding"
    end

    test "multiple finding lines with embedded newlines round-trip through JSON encoding", %{
      conn: conn
    } do
      _rec =
        insert_record!(%{
          finding_count: 3,
          findings_summary:
            "[info] path/to/file.ex:42 — issue one\n[warning] another/file.py:99 — issue two\n[error] third/file.rs:7 — issue three"
        })

      conn = get(conn, ~p"/api/external_reviews", %{workspace_id: @ws})
      response_body = conn.resp_body

      # Must parse with strict JSON decoder
      {:ok, decoded} = Jason.decode(response_body)
      [record] = decoded["data"]

      summary = record["findings_summary"]

      # Verify the summary contains the expected findings
      assert summary =~ "issue one"
      assert summary =~ "issue two"
      assert summary =~ "issue three"

      # Verify the newlines are preserved (they should be there as actual newlines
      # after JSON decoding, since Jason.decode properly unescapes them)
      lines = String.split(summary, "\n")
      assert length(lines) == 3
      assert hd(lines) =~ "issue one"
      assert Enum.at(lines, 1) =~ "issue two"
      assert Enum.at(lines, 2) =~ "issue three"
    end

    test "jq can parse the response body", %{conn: conn} do
      _rec =
        insert_record!(%{
          finding_count: 2,
          findings_summary: "[info] file.ex:10 — first\n[error] file.ex:20 — second"
        })

      conn = get(conn, ~p"/api/external_reviews", %{workspace_id: @ws})
      response_body = conn.resp_body

      # Simulate jq parsing by using Jason.decode which follows same rules
      # jq would use (strict control character escaping)
      assert {:ok, _} = Jason.decode(response_body)
    end

    test "response contains escaped newlines in findings_summary", %{conn: conn} do
      _rec =
        insert_record!(%{
          finding_count: 2,
          findings_summary: "[info] file.ex:10 — first\n[error] file.ex:20 — second"
        })

      conn = get(conn, ~p"/api/external_reviews", %{workspace_id: @ws})
      response_body = conn.resp_body

      # The raw JSON should contain \n escape sequences (\\n in the raw string)
      assert String.contains?(response_body, "\\n"),
             "Response should contain escaped newlines (\\n) in the JSON"
    end

    test "REST and MCP envelope keys (bd-bs5b12)", %{conn: conn} do
      # REST uses :data key, MCP uses :external_reviews key (deliberate asymmetry).
      # This test ensures both transports are correctly documented and don't drift.
      _rec =
        insert_record!(%{
          finding_count: 1,
          findings_summary: "test finding"
        })

      # REST endpoint returns data key (matches /api convention)
      conn = get(conn, ~p"/api/external_reviews", %{workspace_id: @ws})
      {:ok, rest_parsed} = Jason.decode(conn.resp_body)
      assert Map.has_key?(rest_parsed, "data"), "REST should return 'data' key"
      assert is_list(rest_parsed["data"]), "REST data should be a list"
      assert length(rest_parsed["data"]) == 1

      # MCP tool returns external_reviews key (matches other MCP list tools)
      {:ok, mcp_result} =
        Arbiter.MCP.Tools.external_review_list(
          %Arbiter.MCP.Scope{tier: :coordinator, workspace_id: @ws, can_dispatch: true},
          %{}
        )

      assert Map.has_key?(mcp_result, :external_reviews),
             "MCP should return :external_reviews key, got: #{inspect(Map.keys(mcp_result))}"

      assert is_list(mcp_result.external_reviews), "MCP external_reviews should be a list"
      assert length(mcp_result.external_reviews) == 1
    end

    test "REST and MCP both surface failure_stage and failure_reason (bd-7rspia)", %{conn: conn} do
      _rec =
        insert_record!(%{
          status: :failed,
          completed_at: nil,
          failure_stage: "read_diff",
          failure_reason: "forbidden 403: rate limited"
        })

      conn = get(conn, ~p"/api/external_reviews", %{workspace_id: @ws})
      {:ok, rest_parsed} = Jason.decode(conn.resp_body)
      [rest_record] = rest_parsed["data"]
      assert rest_record["failure_stage"] == "read_diff"
      assert rest_record["failure_reason"] == "forbidden 403: rate limited"

      {:ok, mcp_result} =
        Arbiter.MCP.Tools.external_review_list(
          %Arbiter.MCP.Scope{tier: :coordinator, workspace_id: @ws, can_dispatch: true},
          %{}
        )

      [mcp_record] = mcp_result.external_reviews
      assert mcp_record.failure_stage == "read_diff"
      assert mcp_record.failure_reason == "forbidden 403: rate limited"

      {:ok, show_result} =
        Arbiter.MCP.Tools.external_review_show(
          %Arbiter.MCP.Scope{tier: :coordinator, workspace_id: @ws, can_dispatch: true},
          %{"record_id" => mcp_record.id}
        )

      assert show_result.failure_stage == "read_diff"
      assert show_result.failure_reason == "forbidden 403: rate limited"
    end
  end

  describe "GET /api/external_reviews/:id/transcript (bd-7efini)" do
    setup do
      prev = Application.get_env(:arbiter, :output_log_root)

      root =
        Path.join(
          System.tmp_dir!(),
          "review-transcript-api-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev,
          do: Application.put_env(:arbiter, :output_log_root, prev),
          else: Application.delete_env(:arbiter, :output_log_root)
      end)

      :ok
    end

    @stream_json Enum.join(
                   [
                     ~s({"type":"system","subtype":"init","model":"claude-opus-5","session_id":"s-1"}),
                     ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"lib/a.ex"}}]}}),
                     ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"contents"}]}}),
                     ~s({"type":"result","subtype":"success","result":"done"})
                   ],
                   "\n"
                 )

    test "returns the prompt, raw transcript lines and tool uses", %{conn: conn} do
      rec = insert_record!(%{})
      :ok = Arbiter.Worker.PromptLog.write(rec.id, "You are a code reviewer.")
      :ok = Arbiter.Reviews.Transcript.write(rec.id, @stream_json)

      conn = get(conn, ~p"/api/external_reviews/#{rec.id}/transcript")
      body = json_response(conn, 200)["data"]

      assert body["record_id"] == rec.id
      assert body["exists"] == true
      assert body["prompt"] == "You are a code reviewer."
      assert body["line_count"] == 4
      assert length(body["lines"]) == 4
      assert body["tools_used"] == [%{"name" => "Read", "count" => 1}]
      assert [%{"name" => "Read", "result" => "contents"}] = body["tool_uses"]
    end

    test "does not 500 on a multibyte tool result straddling the preview cutoff",
         %{conn: conn} do
      # A `Read` of a real source file: ASCII right up to the 2000-char preview
      # cap, then an em-dash spanning it. A byte-offset slice would hand
      # `json/2` invalid UTF-8 and raise `Jason.EncodeError`.
      long = String.duplicate("a", 1999) <> "— rest of the file " <> String.duplicate("b", 200)

      stream_json =
        Enum.join(
          [
            ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"lib/a.ex"}}]}}),
            Jason.encode!(%{
              "type" => "user",
              "message" => %{
                "content" => [
                  %{"type" => "tool_result", "tool_use_id" => "t1", "content" => long}
                ]
              }
            })
          ],
          "\n"
        )

      rec = insert_record!(%{})
      :ok = Arbiter.Reviews.Transcript.write(rec.id, stream_json)

      conn = get(conn, ~p"/api/external_reviews/#{rec.id}/transcript")
      body = json_response(conn, 200)["data"]

      assert [%{"name" => "Read", "result" => result}] = body["tool_uses"]
      assert String.valid?(result)
      assert String.ends_with?(result, "… [truncated]")
    end

    test "supports tail= and include_prompt=false", %{conn: conn} do
      rec = insert_record!(%{})
      :ok = Arbiter.Worker.PromptLog.write(rec.id, "You are a code reviewer.")
      :ok = Arbiter.Reviews.Transcript.write(rec.id, @stream_json)

      conn =
        get(conn, ~p"/api/external_reviews/#{rec.id}/transcript", %{
          tail: "2",
          include_prompt: "false"
        })

      body = json_response(conn, 200)["data"]

      assert body["prompt"] == nil
      assert length(body["lines"]) == 2
      assert body["truncated"] == true
    end

    test "reports absence rather than 404 for a review with no captured transcript", %{
      conn: conn
    } do
      rec = insert_record!(%{})

      conn = get(conn, ~p"/api/external_reviews/#{rec.id}/transcript")
      body = json_response(conn, 200)["data"]

      assert body["exists"] == false
      assert body["lines"] == []
      assert body["tool_uses"] == []
    end

    test "404s for an unknown record", %{conn: conn} do
      conn = get(conn, ~p"/api/external_reviews/no-such-record/transcript")
      assert json_response(conn, 404)
    end
  end
end
