defmodule Arbiter.MCP.WorkerResumeSlotTest do
  @moduledoc """
  bd-92mx1m acceptance 2/4 on the MCP surface: `worker_resume` of a task that
  released its slot, at a full cap, is refused with a message naming the cap
  and the slot-holding tasks; `force: true` admits it and records the override.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-resume-slot-#{System.unique_integer([:positive])}",
        prefix: "mrs#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    Map.merge(%{ws: ws, coordinator: coordinator}, ResumeSlotFixture.setup_incident(ws))
  end

  test "refuses at a full cap, naming the cap and the holder", ctx do
    assert {:error, {:invalid, message}} =
             Tools.worker_resume(ctx.coordinator, %{"task_id" => ctx.a.id})

    assert message =~ "cap is 1"
    assert message =~ ctx.b.id
    assert message =~ "force"
    assert Worker.whereis(ctx.a.id) == ctx.first.worker_pid
    assert ResumeSlotFixture.overrides(ctx.ws) == []
  end

  test "force: true admits it over the cap and records the override", ctx do
    assert {:ok, data} =
             Tools.worker_resume(ctx.coordinator, %{"task_id" => ctx.a.id, "force" => true})

    assert data.worker.task_id == ctx.a.id
    assert Worker.whereis(ctx.a.id) != ctx.first.worker_pid

    assert [event] = ResumeSlotFixture.overrides(ctx.ws)
    assert event.payload["task_id"] == ctx.a.id
    assert event.payload["actor"] == "coordinator"
  end

  test "the catalog schema accepts `force`" do
    tool = Enum.find(Arbiter.MCP.Catalog.all(), &(&1.name == "worker_resume"))
    assert %{"type" => "boolean"} = tool.input_schema["properties"]["force"]
  end
end
