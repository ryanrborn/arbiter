defmodule GtElixir.GitHubTest do
  # async: false because rate-limit cache lives in :persistent_term (VM-global).
  # Other tests in the suite don't touch it, but parallel tests *within* this
  # module would race on the "rate_limit/0 is nil before any call" assertion.
  use ExUnit.Case, async: false

  alias GtElixir.GitHub
  alias GtElixir.GitHub.Error

  @repo "octo/widget"
  @token "test-token-abc123"

  setup do
    # Reset the persistent_term rate-limit cache between tests so assertions
    # about its contents aren't polluted by sibling tests.
    :persistent_term.erase(:gt_elixir_github_rate_limit)
    :ok
  end

  defp stub(fun), do: Req.Test.stub(GtElixir.GitHub.HTTP, fun)

  defp ratelimit_headers(opts \\ []) do
    [
      {"x-ratelimit-remaining", Keyword.get(opts, :remaining, "4999")},
      {"x-ratelimit-limit", Keyword.get(opts, :limit, "5000")},
      {"x-ratelimit-reset", Keyword.get(opts, :reset, "1747700000")}
    ]
  end

  defp with_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
  end

  describe "pr_open/6" do
    test "POSTs to /repos/:owner/:repo/pulls and returns {:ok, payload}" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/octo/widget/pulls"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded == %{
                 "head" => "feature/x",
                 "base" => "main",
                 "title" => "T",
                 "body" => "B"
               }

        assert ["Bearer " <> _] = Plug.Conn.get_req_header(conn, "authorization")

        conn
        |> with_headers(ratelimit_headers())
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"number" => 42, "state" => "open"})
      end)

      assert {:ok, %{"number" => 42, "state" => "open"}} =
               GitHub.pr_open(@repo, "feature/x", "main", "T", "B", token: @token)
    end

    test "422 maps to {:error, %Error{kind: :validation_failed}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"message" => "Validation Failed"})
      end)

      assert {:error, %Error{kind: :validation_failed, status: 422, message: "Validation Failed"}} =
               GitHub.pr_open(@repo, "x", "main", "T", "B", token: @token)
    end
  end

  describe "pr_get/3" do
    test "GETs /repos/:owner/:repo/pulls/:n and returns parsed map" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/octo/widget/pulls/7"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"state" => "open", "mergeable" => true, "commits" => 3})
      end)

      assert {:ok, %{"state" => "open", "mergeable" => true, "commits" => 3}} =
               GitHub.pr_get(@repo, 7, token: @token)
    end

    test "404 maps to {:error, %Error{kind: :not_found}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:error, %Error{kind: :not_found, status: 404}} =
               GitHub.pr_get(@repo, 999, token: @token)
    end
  end

  describe "pr_list_reviews/3" do
    test "returns the list of reviews" do
      reviews = [
        %{"id" => 1, "state" => "APPROVED", "user" => %{"login" => "alice"}},
        %{"id" => 2, "state" => "CHANGES_REQUESTED", "user" => %{"login" => "bob"}}
      ]

      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/octo/widget/pulls/7/reviews"

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(reviews)
      end)

      assert {:ok, ^reviews} = GitHub.pr_list_reviews(@repo, 7, token: @token)
    end
  end

  describe "pr_comment/4" do
    test "POSTs to /issues/:n/comments with the body" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/octo/widget/issues/7/comments"
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"body" => "LGTM"}

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 10, "body" => "LGTM"})
      end)

      assert {:ok, %{"id" => 10}} = GitHub.pr_comment(@repo, 7, "LGTM", token: @token)
    end
  end

  describe "pr_inline_comment/6" do
    test "POSTs to /pulls/:n/comments with path+line+commit_id" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/octo/widget/pulls/7/comments"
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["path"] == "lib/foo.ex"
        assert decoded["line"] == 42
        assert decoded["body"] == "nit"
        assert decoded["commit_id"] == "deadbeef"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"id" => 99})
      end)

      assert {:ok, %{"id" => 99}} =
               GitHub.pr_inline_comment(@repo, 7, "lib/foo.ex", 42, "nit",
                 token: @token,
                 commit_id: "deadbeef"
               )
    end

    test "fetches PR head SHA when commit_id is not provided" do
      Req.Test.stub(GtElixir.GitHub.HTTP, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/octo/widget/pulls/7"} ->
            conn
            |> Plug.Conn.put_status(200)
            |> Req.Test.json(%{"head" => %{"sha" => "abc123"}})

          {"POST", "/repos/octo/widget/pulls/7/comments"} ->
            {:ok, body, _} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            assert decoded["commit_id"] == "abc123"

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{"id" => 100})

          other ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{unmatched: inspect(other)})
        end
      end)

      assert {:ok, %{"id" => 100}} =
               GitHub.pr_inline_comment(@repo, 7, "lib/foo.ex", 42, "nit", token: @token)
    end
  end

  describe "pr_resolve_thread/3" do
    test "POSTs the resolveReviewThread mutation to /graphql" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/graphql"
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["query"] =~ "resolveReviewThread"
        assert decoded["variables"] == %{"id" => "PRT_thread_node_id"}

        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{
          "data" => %{
            "resolveReviewThread" => %{
              "thread" => %{"id" => "PRT_thread_node_id", "isResolved" => true}
            }
          }
        })
      end)

      assert {:ok, %{"id" => "PRT_thread_node_id", "isResolved" => true}} =
               GitHub.pr_resolve_thread(@repo, "PRT_thread_node_id", token: @token)
    end

    test "GraphQL errors map to {:error, %Error{kind: :validation_failed}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"errors" => [%{"message" => "Could not resolve to a node"}]})
      end)

      assert {:error, %Error{kind: :validation_failed, message: "Could not resolve to a node"}} =
               GitHub.pr_resolve_thread(@repo, "bogus", token: @token)
    end
  end

  describe "pr_merge/4" do
    for strategy <- [:merge, :squash, :rebase] do
      test "PUTs to /pulls/:n/merge with merge_method=#{strategy}" do
        strategy = unquote(strategy)

        stub(fn conn ->
          assert conn.method == "PUT"
          assert conn.request_path == "/repos/octo/widget/pulls/7/merge"
          {:ok, body, _} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == %{"merge_method" => Atom.to_string(strategy)}

          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{"merged" => true, "sha" => "deadbeef"})
        end)

        assert {:ok, %{"merged" => true, "sha" => "deadbeef"}} =
                 GitHub.pr_merge(@repo, 7, strategy, token: @token)
      end
    end
  end

  describe "rate-limit awareness" do
    test "rate-limit headers populate :persistent_term and rate_limit/0 returns them" do
      stub(fn conn ->
        conn
        |> with_headers(ratelimit_headers(remaining: "4321", limit: "5000", reset: "1747700123"))
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"state" => "open"})
      end)

      assert {:ok, _} = GitHub.pr_get(@repo, 7, token: @token)

      assert %{remaining: 4321, limit: 5000, reset_at: %DateTime{}} = GitHub.rate_limit()
    end

    test "rate_limit/0 is nil when no calls have been made" do
      assert GitHub.rate_limit() == nil
    end
  end

  describe "auth + transport" do
    test "missing token (no opts, no env) raises ArgumentError" do
      # Confirm GITHUB_TOKEN is absent for this test (sandbox env).
      original = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")

      try do
        assert_raise ArgumentError, ~r/no token supplied/, fn ->
          GitHub.pr_get(@repo, 7)
        end
      after
        if original, do: System.put_env("GITHUB_TOKEN", original)
      end
    end

    test "transport error maps to {:error, %Error{kind: :network}}" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{kind: :network, status: nil}} =
               GitHub.pr_get(@repo, 7, token: @token)
    end

    test "5xx maps to {:error, %Error{kind: :server_error}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"message" => "service unavailable"})
      end)

      assert {:error, %Error{kind: :server_error, status: 503}} =
               GitHub.pr_get(@repo, 7, token: @token)
    end

    test "401 maps to {:error, %Error{kind: :unauthenticated}}" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"message" => "Bad credentials"})
      end)

      assert {:error, %Error{kind: :unauthenticated, status: 401}} =
               GitHub.pr_get(@repo, 7, token: "bad")
    end
  end
end
