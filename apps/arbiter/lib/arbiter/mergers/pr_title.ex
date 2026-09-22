defmodule Arbiter.Mergers.PRTitle do
  @moduledoc """
  Formats PR/MR titles per the workspace's configured convention.

  By default (`pr_title_format: "raw"`, or not configured) the raw task title
  is passed through unchanged. When a workspace sets
  `config["merge"]["pr_title_format"] = "conventional_commit"`, this module
  produces a Conventional Commits title:

      type: [TICKET] description
      type(scope): [TICKET] description   (if scope is derived)

  - `type` is derived from `issue.issue_type` (see @commit_types).
  - `[TICKET]` is the task's `tracker_ref` (e.g. `AX-17892`) when present,
    else its `tracker_context_ref` — so a context-only child of `VR-19083`
    (#1973) still opens a `[VR-19083]` PR.
  - `description` is the raw title with internal-prefix noise stripped:
    - Leading all-caps team prefix: e.g. `VS: `, `AC: `.
    - Trailing tracker parenthetical that duplicates the bracket ticket:
      e.g. `(AX-17892)` is removed once the ticket appears in `[AX-17892]`.

  ## Config

  Set in the workspace config under `merge.pr_title_format`:

      %{
        "merge" => %{
          "strategy" => "github",
          "pr_title_format" => "conventional_commit",
          "config" => %{ ... }
        }
      }

  Valid values: `"conventional_commit"`, `"raw"` (default).
  """

  alias Arbiter.Tasks.{Issue, Workspace}

  @commit_types %{
    bug: "fix",
    feature: "feat",
    chore: "chore",
    task: "chore",
    epic: "feat",
    decision: "docs"
  }

  @doc """
  Format `issue`'s title for use as a PR/MR title, honouring the workspace's
  `pr_title_format` setting.

  Returns the raw title when `workspace` is `nil` or when the format is `"raw"`.
  """
  @spec format(Issue.t(), Workspace.t() | nil) :: String.t()
  def format(%Issue{title: title}, nil), do: title

  def format(%Issue{} = issue, %Workspace{} = workspace) do
    case Workspace.pr_title_format(workspace) do
      :conventional_commit -> to_conventional_commit(issue)
      _ -> issue.title
    end
  end

  # ---- private helpers --------------------------------------------------------

  defp to_conventional_commit(%Issue{} = issue) do
    type = Map.get(@commit_types, issue.issue_type, "chore")
    ticket = ticket_key(issue)
    desc = clean_description(issue.title, ticket)

    case ticket do
      ref when is_binary(ref) and ref != "" -> "#{type}: [#{ref}] #{desc}"
      _ -> "#{type}: #{desc}"
    end
  end

  defp ticket_key(%Issue{tracker_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp ticket_key(%Issue{tracker_context_ref: ref}), do: ref

  # Strip leading all-caps team prefix ("VS: ", "AC: ", "AX: ", …) and
  # strip the trailing tracker parenthetical that duplicates the bracket ticket.
  defp clean_description(title, tracker_ref) do
    title
    |> strip_internal_prefix()
    |> strip_trailing_ticket(tracker_ref)
    |> String.trim()
  end

  # Remove a leading "UPPERCASE_WORD: " team-namespace prefix.
  # Matches only at the very start of the title and only when the prefix is
  # ALL_CAPS (letters and digits only) so it doesn't accidentally eat a
  # conventional-commit prefix that someone put on the task title.
  defp strip_internal_prefix(title) do
    Regex.replace(~r/^[A-Z][A-Z0-9]*:\s+/, title, "")
  end

  # Remove a trailing "(TICKET)" parenthetical that exactly matches the
  # tracker_ref, since its content will already appear in the "[TICKET]" bracket.
  defp strip_trailing_ticket(title, ref) when is_binary(ref) and ref != "" do
    Regex.replace(~r/\s*\(#{Regex.escape(ref)}\)\s*$/, title, "")
  end

  defp strip_trailing_ticket(title, _ref), do: title
end
