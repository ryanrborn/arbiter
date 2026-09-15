defmodule Arbiter.Tasks.IssueRepoTest do
  @moduledoc """
  bd-9dwbvt: the shared repo resolver every issue-creation path runs through.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.IssueRepo
  alias Arbiter.Tasks.Workspace

  @env_key :repo_paths

  setup do
    prior = Application.get_env(:arbiter, @env_key)
    Application.delete_env(:arbiter, @env_key)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, @env_key, prior),
        else: Application.delete_env(:arbiter, @env_key)
    end)

    :ok
  end

  defp ws!(config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ir-#{System.unique_integer([:positive])}",
        prefix: "ir",
        config: config
      })

    ws
  end

  describe "resolve/2 — no explicit repo" do
    test "auto-fills the workspace's only configured repo" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      assert {:ok, "tonic"} = IssueRepo.resolve(ws.id, nil)
    end

    test "falls back to the workspace default_repo when several are configured" do
      ws =
        ws!(%{
          "repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"},
          "default_repo" => "tonic_device"
        })

      assert {:ok, "tonic_device"} = IssueRepo.resolve(ws.id, nil)
    end

    test "errors with the configured keys when several are configured and no default" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"}})

      assert {:error, {:repo_required, repos}} = IssueRepo.resolve(ws.id, nil)
      assert repos == ["tonic", "tonic_device"]
    end

    test "errors when default_repo names a repo that is not configured" do
      ws =
        ws!(%{
          "repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"},
          "default_repo" => "gone"
        })

      assert {:error, {:repo_required, _}} = IssueRepo.resolve(ws.id, nil)
    end

    test "leaves the repo nil when the workspace configures no repos at all" do
      ws = ws!(%{})

      assert {:ok, nil} = IssueRepo.resolve(ws.id, nil)
    end

    test "leaves the repo nil when there is no workspace" do
      assert {:ok, nil} = IssueRepo.resolve(nil, nil)
    end

    test "sees repos configured in the install-wide application env" do
      Application.put_env(:arbiter, @env_key, %{"arbiter" => "/srv/arbiter"})
      ws = ws!(%{})

      assert {:ok, "arbiter"} = IssueRepo.resolve(ws.id, nil)
    end
  end

  describe "resolve/2 — explicit repo" do
    test "keeps an explicit repo that is a configured key" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"}})

      assert {:ok, "tonic_device"} = IssueRepo.resolve(ws.id, "tonic_device")
    end

    test "an explicit repo wins over a default_repo" do
      ws =
        ws!(%{
          "repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"},
          "default_repo" => "tonic"
        })

      assert {:ok, "tonic_device"} = IssueRepo.resolve(ws.id, "tonic_device")
    end

    test "rejects an explicit repo that is not a configured repo_paths key" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic", "tonic_device" => "/srv/device"}})

      assert {:error, {:repo_not_configured, "nope", repos}} = IssueRepo.resolve(ws.id, "nope")
      assert repos == ["tonic", "tonic_device"]
    end

    test "canonicalizes a loosely-spelled key onto the configured one" do
      ws = ws!(%{"repo_paths" => %{"verus-server" => "/srv/vs"}})

      assert {:ok, "verus-server"} = IssueRepo.resolve(ws.id, "verus_server")
      assert {:ok, "verus-server"} = IssueRepo.resolve(ws.id, "leotech/verus-server")
    end

    test "accepts an explicit repo when the workspace configures no repos at all" do
      ws = ws!(%{})

      assert {:ok, "whatever"} = IssueRepo.resolve(ws.id, "whatever")
    end

    test "treats a blank explicit repo as absent" do
      ws = ws!(%{"repo_paths" => %{"tonic" => "/srv/tonic"}})

      assert {:ok, "tonic"} = IssueRepo.resolve(ws.id, "   ")
    end
  end

  describe "configured_key/2" do
    test "returns the canonical key, or nil when nothing matches" do
      ws = ws!(%{"repo_paths" => %{"verus-server" => "/srv/vs"}})

      assert IssueRepo.configured_key(ws.id, "verus_server") == "verus-server"
      assert IssueRepo.configured_key(ws.id, "nope") == nil
      assert IssueRepo.configured_key(ws.id, nil) == nil
    end
  end
end
