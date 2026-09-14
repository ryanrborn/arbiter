defmodule Arbiter.Mergers.NetDiff do
  @moduledoc """
  A stable fingerprint for a PR's **net contribution** (bd-6bg54c / #1573).

  The reviewed-SHA guard (`Arbiter.Mergers.ReviewedSha`) compares raw commit
  SHAs, so any commit that changes the head refuses the merge — including a
  merge *from the base branch*, which changes the head without changing a
  single line the PR contributes. In the captured incident that shape blocked
  arbiter #1572 outright: `git diff origin/main...<sha> | git patch-id --stable`
  produced the *same* patch-id (`e3d29b52…`) for the reviewed SHA and the head,
  so byte-identical reviewed content sat unmergeable while the Watchdog retried
  303 times.

  This module is the content-level second opinion. Given the PR's diff against
  its merge base at two different heads — what `c:Arbiter.Mergers.Merger.get_diff/2`
  returns for `%{base: base_ref, head: sha}`, which both hosted adapters
  implement as a three-dot (merge-base) compare — `equivalent?/2` answers
  "does the newer head contribute exactly what the reviewer already approved?"

  ## What the normalization removes, and why

  `fingerprint/1` is `git patch-id --stable` in spirit: hash the diff with the
  parts that move for reasons unrelated to content stripped out.

    * **Hunk header ranges** (`@@ -10,6 +10,7 @@`) — a base merge that touched an
      earlier region of the same file shifts every following hunk. The section
      heading after the closing `@@` moves with it, so it goes too.
    * **`index <old>..<new> <mode>` lines** — blob hashes of the *pre-image*
      change whenever the base moves under the PR.
    * **Trailing whitespace** on each line, and blank padding at either end.

  Everything else is retained verbatim, including `diff --git` headers (so a
  file appearing or disappearing changes the fingerprint), every `+`/`-` line,
  and every context line.

  ## How a conflict-resolving merge is detected

  It is detected by *not* being equivalent, which falls out of keeping the
  content lines. A merge from the base that resolves a conflict by writing new
  content necessarily changes the PR's own diff against the merge base — the
  resolved hunk is the PR's contribution now, and it differs from the one the
  reviewer approved. So its fingerprint differs and the head is treated as
  unreviewed, exactly like an authored commit.

  The converse — a clean base merge whose *context* lines shift because the
  base rewrote lines adjacent to the PR's hunk — also changes the fingerprint,
  and is likewise treated as unreviewed. That is deliberate: at the diff level
  a rewritten context line is indistinguishable from an authored one, and the
  guard exists to fail closed. The cost of the false negative is one extra
  review round, not a merge of unreviewed code.
  """

  @typedoc "A hex digest of a normalized net diff, or nil when there was nothing to fingerprint."
  @type t :: String.t() | nil

  @index_prefix "index "

  @doc """
  Fingerprint one unified diff. Returns `nil` when `diff` is not a non-empty
  binary, or normalizes to nothing — an empty diff is never evidence that two
  heads carry the same content (it is far more often evidence that the compare
  call failed or was truncated), so it must not compare equal to anything.
  """
  @spec fingerprint(String.t() | nil) :: t()
  def fingerprint(diff) when is_binary(diff) do
    normalized =
      diff
      |> String.split("\n")
      |> Enum.map(&normalize_line/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
      |> String.trim()

    case normalized do
      "" -> nil
      text -> Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    end
  end

  def fingerprint(_diff), do: nil

  @doc """
  Fingerprint a PR's net contribution by asking its merger adapter for the
  diff (design #1635 §3.3: `net_diff_id` is `fingerprint(base_ref...head_sha)`).

  With both `base` and `head` this is the adapter's three-dot compare of that
  exact range; with either missing it falls back to the whole-PR diff, which
  both hosted adapters already serve as `base...head`. Every failure — an
  adapter that does not implement `get_diff/2`, a wire error, a raise, an exit
  — resolves to `nil`, the same "could not tell" value `fingerprint/1` returns
  for an empty diff. A caller that needs a real fingerprint must treat `nil` as
  a failed computation, never as evidence of equality.
  """
  @spec fingerprint_pr(module(), String.t(), String.t() | nil, String.t() | nil) :: t()
  def fingerprint_pr(adapter, mr_ref, base, head)
      when is_atom(adapter) and is_binary(mr_ref) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :get_diff, 2) do
      case adapter.get_diff(mr_ref, compare_opts(base, head)) do
        {:ok, diff} -> fingerprint(diff)
        _ -> nil
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def fingerprint_pr(_adapter, _mr_ref, _base, _head), do: nil

  @doc """
  Fingerprint a branch's net contribution from a local worktree, by running
  `git -C <path> diff <range>`.

  `range` is the caller's own diff range (e.g. `"<merge_base>..HEAD"`) so the
  fingerprint covers exactly what the reviewer was shown. `nil` on any git
  failure or an empty diff, with the same "could not tell" meaning as
  `fingerprint_pr/4`.
  """
  @spec fingerprint_local(String.t(), String.t()) :: t()
  def fingerprint_local(worktree_path, range)
      when is_binary(worktree_path) and is_binary(range) do
    case System.cmd("git", ["-C", worktree_path, "diff", range], stderr_to_stdout: true) do
      {out, 0} -> fingerprint(out)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def fingerprint_local(_worktree_path, _range), do: nil

  # Both endpoints present → a bounded `base...head` compare; otherwise the
  # adapter's whole-PR diff, which is already the PR's net contribution.
  defp compare_opts(base, head)
       when is_binary(base) and is_binary(head) and base != "" and head != "",
       do: %{base: base, head: head}

  defp compare_opts(_base, _head), do: %{}

  @doc """
  Do two diffs describe the same net contribution?

  `false` whenever either side could not be fingerprinted — the caller is about
  to decide whether to merge, so "we could not tell" must read as "not the
  same".
  """
  @spec equivalent?(String.t() | nil, String.t() | nil) :: boolean()
  def equivalent?(left, right) do
    case {fingerprint(left), fingerprint(right)} do
      {nil, _} -> false
      {_, nil} -> false
      {same, same} -> true
      _ -> false
    end
  end

  # Hunk headers carry line numbers (and a section heading) that move whenever
  # the base branch shifts the surrounding file; keep the marker, drop the rest.
  defp normalize_line("@@ " <> _rest), do: "@@"

  # Pre/post-image blob hashes churn with the base branch, not with content.
  defp normalize_line(@index_prefix <> _rest), do: nil

  defp normalize_line(line), do: String.trim_trailing(line)
end
