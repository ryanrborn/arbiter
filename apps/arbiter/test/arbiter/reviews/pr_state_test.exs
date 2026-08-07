defmodule Arbiter.Reviews.PrStateTest do
  @moduledoc """
  Unit coverage for the shared pr_state resolver (bd-3jjk0e):

    * `needs_refresh?/1` — retry predicate, including the previously dead-end
      `"unknown"` state and the new terminal sentinels.
    * `classify/1` — adapter-result → state-string mapping (open / merged /
      closed / 404-terminal / transient-unknown).
    * `resolve/2` — short-circuit terminal sentinels for direct / no-PR reviews,
      plus the full HTTP path through the GitHub adapter.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Github.{Config, Error}
  alias Arbiter.Reviews.PrState

  @env_var "PR_STATE_TEST_GITHUB_TOKEN"

  setup do
    System.put_env(@env_var, "test-token")

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  # A raw merger-config map — `with_workspace/2` accepts this directly and
  # `Config.put_active/1` stores it verbatim, so no DB Workspace is needed.
  defp github_ws do
    %{
      "owner" => "octo",
      "repo" => "widget",
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main",
      "merge_method" => "squash"
    }
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  describe "needs_refresh?/1" do
    test "nil pr_state is retryable (never resolved yet)" do
      assert PrState.needs_refresh?(%{pr_state: nil, status: :completed})
    end

    test "\"open\" is retryable (may transition to merged/closed)" do
      assert PrState.needs_refresh?(%{pr_state: "open", status: :completed})
    end

    test "\"unknown\" is retryable (was a dead-end before this fix)" do
      assert PrState.needs_refresh?(%{pr_state: "unknown", status: :completed})
    end

    test "a :running review is retryable regardless of pr_state" do
      assert PrState.needs_refresh?(%{pr_state: nil, status: :running})
    end

    test "\"merged\" is terminal (frozen)" do
      refute PrState.needs_refresh?(%{pr_state: "merged", status: :completed})
    end

    test "\"closed\" is terminal (frozen)" do
      refute PrState.needs_refresh?(%{pr_state: "closed", status: :completed})
    end

    test "\"gone\" is frozen while its confirmation is still fresh (within the recheck TTL)" do
      refute PrState.needs_refresh?(%{
               pr_state: "gone",
               status: :completed,
               gone_at: DateTime.utc_now()
             })
    end

    test "\"gone\" becomes retryable again once its confirmation goes stale (TTL re-verification, bd-7qzqfs)" do
      stale_at = DateTime.add(DateTime.utc_now(), -8, :day)

      assert PrState.needs_refresh?(%{pr_state: "gone", status: :completed, gone_at: stale_at})
    end

    test "\"gone\" with no gone_at (legacy row, or one written before this fix) is retryable — self-heals" do
      assert PrState.needs_refresh?(%{pr_state: "gone", status: :completed})
    end

    test "\"n/a\" (no forge PR) is terminal (frozen)" do
      refute PrState.needs_refresh?(%{pr_state: "n/a", status: :completed})
    end
  end

  describe "classify/1 (outcome mapping)" do
    test "open PR → \"open\"" do
      assert PrState.classify({:ok, %{status: :open}}) == "open"
    end

    test "merged PR → \"merged\"" do
      assert PrState.classify({:ok, %{status: :merged}}) == "merged"
    end

    test "closed PR → \"closed\"" do
      assert PrState.classify({:ok, %{status: :closed}}) == "closed"
    end

    test "404 not-found → intermediate \"not_found\" signal (not directly terminal — bd-7qzqfs)" do
      assert PrState.classify({:error, %Error{kind: :not_found, status: 404}}) == "not_found"
    end

    test "any struct-shaped not_found error → intermediate \"not_found\" signal" do
      assert PrState.classify({:error, %{kind: :not_found, status: 404}}) == "not_found"
    end

    test "transient server error → \"unknown\" (retry)" do
      assert PrState.classify({:error, %Error{kind: :server_error, status: 503}}) == "unknown"
    end

    test "transport/network error → \"unknown\" (retry)" do
      assert PrState.classify({:error, :unsupported}) == "unknown"
    end
  end

  describe "resolve/2 short-circuit terminal sentinels" do
    test "direct strategy → terminal \"n/a\" (no forge PR to poll)" do
      assert PrState.resolve(%{strategy: "direct", pr_ref: "whatever"}, nil) == "n/a"
    end

    test "nil strategy → terminal \"n/a\"" do
      assert PrState.resolve(%{strategy: nil, pr_ref: "whatever"}, nil) == "n/a"
    end

    test "blank pr_ref → terminal \"n/a\"" do
      assert PrState.resolve(%{strategy: "github", pr_ref: ""}, github_ws()) == "n/a"
    end
  end

  describe "resolve/2 full HTTP path (github)" do
    test "an open PR resolves to \"open\"" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            Req.Test.json(conn, %{"state" => "open", "merged" => false, "html_url" => "u"})

          _ ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert PrState.resolve(%{strategy: "github", pr_ref: "octo/widget#42"}, github_ws()) ==
               "open"
    end

    test "a merged PR resolves to \"merged\"" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            Req.Test.json(conn, %{"state" => "closed", "merged" => true, "html_url" => "u"})

          _ ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert PrState.resolve(%{strategy: "github", pr_ref: "octo/widget#42"}, github_ws()) ==
               "merged"
    end

    test "a 404 resolves to the intermediate \"not_found\" signal, not directly \"gone\" (bd-7qzqfs)" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert PrState.resolve(%{strategy: "github", pr_ref: "octo/widget#42"}, github_ws()) ==
               "not_found"
    end

    test "a strategy-prefixed pr_ref still resolves (adapter tolerates the prefix)" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            Req.Test.json(conn, %{"state" => "open", "merged" => false, "html_url" => "u"})

          _ ->
            conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
        end
      end)

      assert PrState.resolve(%{strategy: "github", pr_ref: "github:octo/widget#42"}, github_ws()) ==
               "open"
    end
  end
end
