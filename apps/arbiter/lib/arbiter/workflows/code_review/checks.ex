defmodule Arbiter.Workflows.CodeReview.Checks do
  @moduledoc """
  Default check runner for `Arbiter.Workflows.CodeReview`.

  Phase 2 is intentionally a no-op: it returns `{:ok, []}` for any diff.
  Real check execution (linters, type checkers, custom heuristics keyed off
  the bead's acceptance criteria) is a follow-up — see the BUILD-SUMMARY.

  The workflow looks up the runner indirectly via `state[:check_runner]`
  (defaulting to `&__MODULE__.run/2`), which lets tests inject a stub
  without monkey-patching modules.

  ## Finding shape

  Each finding is a map with these keys:

      %{
        severity: :info | :warning | :error,
        file: String.t(),
        line: pos_integer(),
        message: String.t()
      }

  Any finding with `severity: :error` causes the workflow's `:verdict` step
  to return `:request_changes`; otherwise `:approve`.
  """

  @type severity :: :info | :warning | :error
  @type finding :: %{
          required(:severity) => severity(),
          required(:file) => String.t(),
          required(:line) => pos_integer(),
          required(:message) => String.t()
        }

  @doc """
  Run checks against a diff and a state context. Phase 2: always returns
  `{:ok, []}`.
  """
  @spec run(String.t(), map()) :: {:ok, [finding()]} | {:error, term()}
  def run(_diff, _state), do: {:ok, []}
end
