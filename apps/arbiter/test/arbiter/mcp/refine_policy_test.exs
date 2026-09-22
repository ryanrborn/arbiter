defmodule Arbiter.MCP.RefinePolicyTest do
  @moduledoc """
  The `:refine` tier's tool-level allow/deny table (bd-3uy2hn, acceptance 2 & 5).

  The conformance test here is the point of the module: a tool added to
  `Arbiter.MCP.Catalog` with no entry in the table fails this suite, so no tool
  can ever silently default into (or out of) a refine session's authority.
  """
  use ExUnit.Case, async: true

  alias Arbiter.MCP.Catalog
  alias Arbiter.MCP.RefinePolicy
  alias Arbiter.MCP.Scope

  @refine %Scope{tier: :refine, workspace_id: "w", issue_id: "bd-root", session_id: "s"}

  describe "conformance — every tool is decided" do
    test "no catalog tool is missing a refine decision" do
      undecided =
        Catalog.all()
        |> Enum.map(& &1.name)
        |> Enum.filter(&(RefinePolicy.decision(&1) == :undecided))

      assert undecided == [],
             """
             These MCP tools have no `:refine`-tier decision in Arbiter.MCP.RefinePolicy:

                 #{Enum.join(undecided, "\n    ")}

             Every tool must be explicitly allowed or denied for a refine session.
             Add each to @allow or @deny (with a reason) in refine_policy.ex.
             """
    end

    test "the table names no tool that does not exist in the catalog" do
      catalog = MapSet.new(Catalog.all(), & &1.name)
      stale = Enum.reject(RefinePolicy.decided(), &MapSet.member?(catalog, &1))

      assert stale == [],
             "RefinePolicy decides tools that are not in the catalog: #{inspect(stale)}"
    end

    test "every decision is either :allow or a {:deny, reason} with a non-empty reason" do
      for name <- RefinePolicy.decided() do
        case RefinePolicy.decision(name) do
          :allow ->
            :ok

          {:deny, reason} ->
            assert is_binary(reason) and reason != "", "#{name} has a blank deny reason"
        end
      end
    end
  end

  describe "the shape of the permission set" do
    test "the read surface a refinement actually needs is allowed" do
      for tool <- ~w(task_show task_list task_ready workspace_show workspace_config_get
                     workspace_config_overview repo_list repo_show
                     skill_list skill_get) do
        assert RefinePolicy.allow?(tool), "expected #{tool} to be allowed for a refine session"
      end
    end

    test "the subtree write surface is allowed" do
      for tool <- ~w(task_update task_update_progress task_create task_promote dep_add dep_remove) do
        assert RefinePolicy.allow?(tool), "expected #{tool} to be allowed for a refine session"
      end
    end

    test "status-changing, dispatching and installation-wide tools are denied" do
      for tool <- ~w(task_close task_reopen task_verify task_sync_upstream_close
                     worker_dispatch worker_resume worker_review worker_stop worker_list
                     worker_show worker_runs worker_log worker_prompt
                     scheduler_pause scheduler_resume scheduler_status
                     workspace_config_set workspace_config_unset
                     installation_config_get installation_config_set
                     skill_create skill_update skill_delete
                     message_send review_greenlight) do
        refute RefinePolicy.allow?(tool), "expected #{tool} to be denied for a refine session"
      end
    end
  end

  describe "Catalog integration" do
    test "visible/1 lists exactly the allowed tools for a refine scope" do
      visible = @refine |> Catalog.visible() |> Enum.map(& &1.name) |> Enum.sort()

      assert visible == Enum.sort(RefinePolicy.allowed())
    end

    test "a denied tool is refused with a not-permitted rpc error naming the reason" do
      assert {:rpc_error, -32_003, message} = Catalog.call(@refine, "worker_dispatch", %{})
      assert message =~ "worker_dispatch"
      assert message =~ "refine"
    end

    test "each denied group is refused before the handler ever runs" do
      # No DataCase here: if any of these reached its handler it would need the
      # repo, and the test would blow up rather than quietly pass.
      for {tool, args} <- [
            {"worker_dispatch", %{"task_id" => "bd-x"}},
            {"task_close", %{"id" => "bd-x"}},
            {"workspace_config_set", %{"key" => "a", "value" => "b"}},
            {"scheduler_pause", %{}},
            {"queue_restart_watchdog", %{"task_id" => "bd-x"}},
            {"worker_stop", %{"task_id" => "bd-x"}},
            {"message_send", %{"to" => "coordinator", "body" => "hi"}},
            {"review_greenlight", %{"task_id" => "bd-x"}},
            {"installation_config_set", %{}}
          ] do
        assert {:rpc_error, -32_003, _} = Catalog.call(@refine, tool, args),
               "expected #{tool} to be refused for a refine scope"
      end
    end

    test "worker and coordinator visibility is untouched by the refine table" do
      worker = %Scope{tier: :worker, workspace_id: "w", task_id: "bd-1"}
      coordinator = %Scope{tier: :coordinator}

      for %{name: name, tiers: tiers} <- Catalog.all() do
        assert name in Enum.map(Catalog.visible(worker), & &1.name) == :worker in tiers

        assert name in Enum.map(Catalog.visible(coordinator), & &1.name) ==
                 :coordinator in tiers
      end
    end
  end
end
