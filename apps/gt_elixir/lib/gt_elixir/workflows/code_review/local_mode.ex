defmodule GtElixir.Workflows.CodeReview.LocalMode do
  @moduledoc """
  Local-mode side-effects for `GtElixir.Workflows.CodeReview`.

  Local mode writes a structured Markdown file at
  `<worktree_path>/reviews/<sanitized-branch>.md`. The format mirrors the
  Go GT polecat-reviewer convention: a header naming the branch + bead, a
  pending verdict line that is rewritten in the `:verdict` step, and one
  section per finding ordered by severity.

  Branch names with `/` are sanitized to `-` to keep the file path flat.
  """

  @type finding :: GtElixir.Workflows.CodeReview.Checks.finding()

  @doc """
  Return the absolute path of the review file for the given worktree and
  branch.
  """
  @spec review_path(String.t(), String.t()) :: String.t()
  def review_path(worktree_path, branch) when is_binary(worktree_path) and is_binary(branch) do
    leaf = String.replace(branch, "/", "-") <> ".md"
    Path.join([worktree_path, "reviews", leaf])
  end

  @doc """
  Write the initial review file with a pending verdict. The file is
  overwritten if it already exists.
  """
  @spec write_findings(String.t(), String.t(), map() | nil, [finding()]) :: :ok
  def write_findings(worktree_path, branch, bead, findings)
      when is_binary(worktree_path) and is_binary(branch) and is_list(findings) do
    path = review_path(worktree_path, branch)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, render_initial(branch, bead, findings))
    :ok
  end

  @doc """
  Rewrite the file in place with a final verdict line.
  """
  @spec set_verdict(String.t(), :approve | :request_changes) :: :ok
  def set_verdict(path, verdict)
      when is_binary(path) and verdict in [:approve, :request_changes] do
    contents = File.read!(path)

    rewritten =
      String.replace(
        contents,
        ~r/^\*\*Verdict.*$/m,
        "**Verdict:** #{verdict_label(verdict)}",
        global: false
      )

    File.write!(path, rewritten)
    :ok
  end

  # ---- formatting ---------------------------------------------------------

  defp render_initial(branch, bead, findings) do
    sorted = sort_findings(findings)

    bead_line =
      case bead do
        %{id: id, title: title} -> "**Bead:** #{id} — #{title}"
        %{"id" => id, "title" => title} -> "**Bead:** #{id} — #{title}"
        _ -> "**Bead:** (none)"
      end

    [
      "# Code review: #{branch}\n",
      "\n",
      bead_line,
      "\n",
      "**Mode:** local\n",
      "**Verdict (pending):** _to be set in :verdict step_\n",
      "\n",
      "## Findings\n",
      "\n",
      "(#{length(findings)} findings)\n",
      "\n",
      Enum.map(sorted, &render_finding/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp render_finding(%{severity: sev, file: file, line: line, message: msg}) do
    [
      "### #{file}:#{line} — #{Atom.to_string(sev)}\n",
      msg,
      "\n\n"
    ]
  end

  # Sort by severity (error > warning > info), then by file, then line.
  defp sort_findings(findings) do
    Enum.sort_by(findings, fn %{severity: s, file: f, line: l} -> {-severity_rank(s), f, l} end)
  end

  defp severity_rank(:error), do: 2
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 0
  defp severity_rank(_), do: 0

  defp verdict_label(:approve), do: "APPROVE"
  defp verdict_label(:request_changes), do: "REQUEST_CHANGES"
end
