defmodule Arbiter.Test.SessionRunnerStub do
  @moduledoc """
  Test double for `Arbiter.Sessions.Runner` (bd-bpt0ag).

  Every session control operation shells out, so the injectable runner is the
  whole test seam: the stub records each `{command, args, opts}` and replies
  from a scripted function. State lives in the **process dictionary** of the
  calling process, which is safe here because `Arbiter.Sessions` runs every
  command synchronously in the caller's process — that is the same property
  that makes "no Elixir process holds the PTY" true.

      SessionRunnerStub.script(fn
        "systemd-run", _args, _opts -> {"", 0}
        "systemctl", _args, _opts -> {"", 0}
      end)

      {:ok, session} = Sessions.launch(cwd: "/tmp", runner: SessionRunnerStub)

      assert [{"systemd-run", args, _}] = SessionRunnerStub.calls()
  """

  @behaviour Arbiter.Sessions.Runner

  @script :"$arbiter_session_runner_stub_script"
  @calls :"$arbiter_session_runner_stub_calls"

  @doc "Install the reply function for this process. Default: success, no output."
  @spec script((String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})) :: :ok
  def script(fun) when is_function(fun, 3) do
    Process.put(@script, fun)
    :ok
  end

  @doc "Every call this process made, in order."
  @spec calls() :: [{String.t(), [String.t()], keyword()}]
  def calls, do: Enum.reverse(Process.get(@calls, []))

  @doc "Calls for one command only, in order."
  @spec calls(String.t()) :: [{String.t(), [String.t()], keyword()}]
  def calls(command), do: Enum.filter(calls(), fn {cmd, _, _} -> cmd == command end)

  @doc "Forget recorded calls (not the script)."
  @spec reset() :: :ok
  def reset do
    Process.delete(@calls)
    :ok
  end

  @impl Arbiter.Sessions.Runner
  def run(command, args, opts) do
    Process.put(@calls, [{command, args, opts} | Process.get(@calls, [])])

    case Process.get(@script) do
      nil -> {"", 0}
      fun -> fun.(command, args, opts)
    end
  end
end
