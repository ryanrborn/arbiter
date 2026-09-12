defmodule Arbiter.Quota.RefreshProbeLedgerTest do
  @moduledoc """
  bd-adyhvn acceptance 5: a RefreshProbe's spend appears in the usage ledger
  under `source: :probe`, and `arb usage --by task` does not grow a phantom
  task for it.

  The probe runs its **real** capture path here — the same
  `claude --print --output-format json ok` port spawn production uses — with
  `:claude_path` pointed at a stub script that prints the CLI's own result
  object. Nothing is stubbed downstream of the port.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.RefreshProbe
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage
  alias Arbiter.Usage.Event
  require Ash.Query

  @usage_json ~s({"type":"result","subtype":"success","is_error":false,) <>
                ~s("duration_ms":1234,"num_turns":1,"result":"ok","session_id":"sess-rp-1",) <>
                ~s("total_cost_usd":0.0181,) <>
                ~s("usage":{"input_tokens":4,"output_tokens":7,) <>
                ~s("cache_creation_input_tokens":11,"cache_read_input_tokens":57062}})

  defp make_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rpl-ws-#{System.unique_integer([:positive])}",
        prefix: "rpl#{System.unique_integer([:positive])}"
      })

    ws
  end

  # A stub `claude` that prints the result object the real CLI prints for
  # `--output-format json`. Worktree-unique name: /tmp is shared between
  # workers on this host.
  defp stub_claude!(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "arb-adyhvn-claude-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}.sh"
      )

    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a probe's spend lands in the ledger under source: :probe" do
    ws = make_workspace()
    claude = stub_claude!("cat <<'JSON'\n#{@usage_json}\nJSON")

    assert :ok = RefreshProbe.probe_once(ws.id, claude_path: claude, timeout_ms: 30_000)

    [ev] = Event |> Ash.Query.filter(source == :probe) |> Ash.read!()

    assert ev.workspace_id == ws.id
    assert ev.task_id == nil
    assert ev.tokens_in == 4
    assert ev.tokens_out == 7
    assert ev.cache_creation_tokens == 11
    assert ev.cache_read_tokens == 57_062
    assert ev.session_id == "sess-rp-1"
  end

  test "--by task excludes the probe row while --by source surfaces it" do
    ws = make_workspace()
    claude = stub_claude!("cat <<'JSON'\n#{@usage_json}\nJSON")

    {:ok, _} =
      Ash.create(Event, %{
        task_id: "bd-rpl-real",
        workspace_id: ws.id,
        step: :work,
        cost_usd: 1.0,
        occurred_at: DateTime.utc_now()
      })

    assert :ok = RefreshProbe.probe_once(ws.id, claude_path: claude, timeout_ms: 30_000)

    {:ok, by_task} = Usage.summarize(by: :task, workspace_id: ws.id)
    assert Enum.map(by_task, & &1.group) == ["bd-rpl-real"]

    {:ok, by_source} = Usage.summarize(by: :source, workspace_id: ws.id)
    groups = Map.new(by_source, &{&1.group, &1})
    assert groups["probe"].rows == 1
    assert groups["probe"].cache_read_tokens == 57_062
    assert groups["task"].rows == 1
  end

  test "a probe that fails still records the attempt" do
    ws = make_workspace()
    claude = stub_claude!("echo 'boom' >&2; exit 3")

    assert {:error, {:exit_code, 3}} =
             RefreshProbe.probe_once(ws.id, claude_path: claude, timeout_ms: 30_000)

    [ev] = Event |> Ash.Query.filter(source == :probe) |> Ash.read!()
    assert ev.exit_status == 3
    assert ev.tokens_in == nil
  end
end
