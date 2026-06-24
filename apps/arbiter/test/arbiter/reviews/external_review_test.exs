defmodule Arbiter.Reviews.ExternalReviewTest do
  # async: false — the GitHub merger uses the process-global Req.Test stub
  # registry and the per-process active-config dictionary.
  use Arbiter.DataCase, async: false

  alias Arbiter.Reviews.ExternalReview
  alias Arbiter.Tasks.Workspace

  @env_var "EXTERNAL_REVIEW_GH_TOKEN"

  defp uniq_prefix, do: "er" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp github_ws(name) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: name,
        prefix: uniq_prefix(),
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "octo",
              "repo" => "widget",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    ws
  end

  describe "prepare/1 — validation & resolution" do
    test "missing pr returns :pr_required" do
      github_ws("er-prep-1")
      assert {:error, :pr_required} = ExternalReview.prepare(pr: "")
      assert {:error, :pr_required} = ExternalReview.prepare(%{})
    end

    test "resolves the github MR adapter and an embedded ref from a PR URL" do
      ws = github_ws("er-prep-2")

      assert {:ok, prepared} =
               ExternalReview.prepare(
                 pr: "https://github.com/leo/verus_sigv4/pull/5",
                 workspace: ws.name
               )

      assert prepared.adapter == Arbiter.Mergers.Github
      assert prepared.strategy == :github
      assert prepared.mr_ref == "leo/verus_sigv4#5"
      assert prepared.link == "https://github.com/leo/verus_sigv4/pull/5"
    end

    test "resolves repo_path from workspace config and embeds owner/repo for a bare number" do
      repo = tmp_git_repo("git@github.com:leo/verus_auth_server.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "er-prep-3",
          prefix: uniq_prefix(),
          config: %{
            "repo_paths" => %{"verus_auth_server" => repo},
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert {:ok, prepared} =
               ExternalReview.prepare(pr: "394", repo: "verus_auth_server", workspace: ws.name)

      assert prepared.mr_ref == "leo/verus_auth_server#394"
    end

    test "the :direct merge strategy has no external-PR support" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "er-direct",
          prefix: uniq_prefix(),
          config: %{"merge" => %{"strategy" => "direct"}}
        })

      assert {:error, {:unsupported_strategy, :direct}} =
               ExternalReview.prepare(pr: "1", workspace: ws.name)
    end

    test "an unknown workspace name is reported" do
      assert {:error, {:workspace, msg}} =
               ExternalReview.prepare(pr: "1", workspace: "does-not-exist")

      assert msg =~ "not found"
    end

    test "nil workspace resolves the lone installation workspace" do
      ws = github_ws("er-sole")

      assert {:ok, prepared} = ExternalReview.prepare(pr: "octo/widget#3")
      assert prepared.workspace.id == ws.id
      assert prepared.mr_ref == "octo/widget#3"
    end
  end

  describe "review/1 — end-to-end against the GitHub adapter" do
    setup do
      System.put_env(@env_var, "test-token")
      on_exit(fn -> System.delete_env(@env_var) end)
      :ok
    end

    test "reads the diff, posts a finding, submits a verdict, returns it" do
      github_ws("er-e2e")
      events = :ets.new(:er_events, [:public, :duplicate_bag])

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and
              "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+boom\n")

          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"number" => 42, "head" => %{"sha" => "abc"}}))

          conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
            :ets.insert(events, {:comment, true})

            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(201, Jason.encode!(%{"id" => 1}))

          conn.method == "POST" and path == "/repos/octo/widget/pulls/42/reviews" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            :ets.insert(events, {:review, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 99}))

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "unhandled #{path}"}))
        end
      end)

      runner = fn _diff, _state ->
        {:ok, [%{severity: :error, file: "x.ex", line: 1, message: "boom"}]}
      end

      assert {:ok, result} =
               ExternalReview.review(pr: "octo/widget#42", check_runner: runner)

      assert result.verdict == :request_changes
      assert result.findings == 1
      assert result.mr_ref == "octo/widget#42"
      assert [{:comment, true}] = :ets.lookup(events, :comment)
      assert [{:review, review}] = :ets.lookup(events, :review)
      assert review["event"] == "REQUEST_CHANGES"
    end

    test "no findings → an approve verdict is submitted" do
      github_ws("er-e2e-approve")

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        cond do
          "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+ok\n")

          conn.method == "POST" and conn.request_path =~ ~r{/reviews$} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(self(), {:review_event, Jason.decode!(body)["event"]})

            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 1}))

          true ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{}))
        end
      end)

      runner = fn _diff, _state -> {:ok, []} end

      assert {:ok, %{verdict: :approve}} =
               ExternalReview.review(pr: "octo/widget#1", check_runner: runner)
    end
  end

  defp tmp_git_repo(origin_url) do
    dir = Path.join(System.tmp_dir!(), "er-ref-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", origin_url])
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
