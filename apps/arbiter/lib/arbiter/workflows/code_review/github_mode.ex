defmodule Arbiter.Workflows.CodeReview.GithubMode do
  @moduledoc """
  GitHub-mode side-effects for `Arbiter.Workflows.CodeReview`.

  Wraps `Arbiter.GitHub` calls used by the workflow:

    * `post_findings/4` — one inline comment per finding (via
      `GitHub.pr_inline_comment/6`), plus a single top-level summary comment
      (via `GitHub.pr_comment/4`).
    * `post_verdict/4` — submits the review verdict via
      `GitHub.pr_review/5`.

  The workflow itself does **not** call `GitHub.pr_merge/4`. Merging is the
  responsibility of the polecat-orchestrator after a successful review;
  reviewers escalate to the Mayor if they are unsure.
  """

  alias Arbiter.GitHub

  @type finding :: Arbiter.Workflows.CodeReview.Checks.finding()

  @doc """
  Post each finding as an inline review comment, plus a single top-level
  summary comment. Returns `:ok` if all posts succeeded, otherwise
  `{:error, reason}` on the first failure.
  """
  @spec post_findings(GitHub.repo(), GitHub.pr_number(), [finding()], keyword()) ::
          :ok | {:error, term()}
  def post_findings(repo, pr_number, findings, opts \\ []) do
    with :ok <- post_inline_comments(repo, pr_number, findings, opts),
         {:ok, _} <- GitHub.pr_comment(repo, pr_number, summary_body(findings), opts) do
      :ok
    end
  end

  @doc """
  Submit the final review verdict. `body` is the review summary; pass `""`
  for no summary.
  """
  @spec post_verdict(
          GitHub.repo(),
          GitHub.pr_number(),
          :approve | :request_changes,
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def post_verdict(repo, pr_number, verdict, body \\ "", opts \\ [])
      when verdict in [:approve, :request_changes] do
    GitHub.pr_review(repo, pr_number, verdict, body, opts)
  end

  # ---- internals ---------------------------------------------------------

  defp post_inline_comments(repo, pr_number, findings, opts) do
    Enum.reduce_while(findings, :ok, fn finding, :ok ->
      %{file: file, line: line, message: msg, severity: sev} = finding
      body = "**#{Atom.to_string(sev) |> String.upcase()}**: #{msg}"

      case GitHub.pr_inline_comment(repo, pr_number, file, line, body, opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp summary_body([]), do: "Automated review: no findings."

  defp summary_body(findings) do
    counts = Enum.frequencies_by(findings, & &1.severity)
    err = Map.get(counts, :error, 0)
    warn = Map.get(counts, :warning, 0)
    info = Map.get(counts, :info, 0)

    "Automated review: #{length(findings)} findings " <>
      "(#{err} error, #{warn} warning, #{info} info)."
  end
end
