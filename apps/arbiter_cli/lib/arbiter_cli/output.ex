defmodule ArbiterCli.Output do
  @moduledoc """
  Formatting + exit helpers shared across subcommand modules.

  Two output modes:

    * `:text` — human-readable, default. Mimics the shape of the Go `bd` CLI
      closely enough that muscle memory works.
    * `:json` — single JSON object or `{"data":[...]}` for list output.

  Plus error reporting helpers (`die/1`, `die/2`) that print to stderr and
  halt the VM with a non-zero status.
  """

  alias ArbiterCli.Client

  # ----- mode resolution -----

  @doc """
  Splits `--json` (and `-h`/`--help`) out of an argv list, returning
  `{mode, remaining_argv}`. Used by every subcommand so we don't repeat the
  parser invocation.
  """
  @spec extract_mode([String.t()]) :: {:text | :json, [String.t()]}
  def extract_mode(argv) do
    {opts, rest, _invalid} =
      OptionParser.parse(argv, switches: [json: :boolean], allow_nonexistent_atoms?: true)

    mode = if opts[:json], do: :json, else: :text
    # Strip the parsed flag from rest by re-collecting non-flag args + leftover flags
    stripped = Enum.reject(argv, &(&1 == "--json"))
    {mode, stripped -- (argv -- rest)}
  end

  @doc """
  Lighter variant: keeps full argv but tells us the mode. Subcommands can
  parse their own flags afterwards; the `--json` flag is harmless to leave
  in for OptionParser since it'll just be ignored.
  """
  @spec mode([String.t()]) :: :text | :json
  def mode(argv) do
    if "--json" in argv, do: :json, else: :text
  end

  @doc "Returns true if `--help` or `-h` is present in argv."
  @spec help?([String.t()]) :: boolean()
  def help?(argv), do: "--help" in argv or "-h" in argv

  # Removes `--json` from an argv list so command-specific OptionParser calls
  # don't trip on it.
  @spec drop_json([String.t()]) :: [String.t()]
  def drop_json(argv), do: Enum.reject(argv, &(&1 == "--json"))

  # ----- emit -----

  @doc "Print a single issue or other resource map. Mode-aware."
  @spec emit_issue(map(), :text | :json) :: :ok
  def emit_issue(issue, :json), do: IO.puts(Jason.encode!(issue))
  def emit_issue(issue, :text), do: IO.puts(format_issue_detail(issue))

  @doc """
  Print an upstream tracker ticket created via `--ticket-only`. Mode-aware.

  Text: `{tracker_type}:{ref}\\n{url}` (or just ref if URL is absent).
  JSON: raw response map.
  """
  @spec emit_ticket(map(), :text | :json) :: :ok
  def emit_ticket(ticket, :json), do: IO.puts(Jason.encode!(ticket))

  def emit_ticket(ticket, :text) do
    tracker_type = ticket["tracker_type"] || "tracker"
    ref = ticket["ref"] || ""
    url = ticket["url"]

    IO.puts("#{tracker_type}:#{ref}")
    if url && url != "", do: IO.puts(url)
  end

  @doc "Print a list of issues. Mode-aware."
  @spec emit_issue_list([map()], :text | :json) :: :ok
  def emit_issue_list(issues, :json), do: IO.puts(Jason.encode!(%{data: issues}))

  def emit_issue_list(issues, :text) do
    case issues do
      [] ->
        IO.puts("(no issues)")

      list ->
        Enum.each(list, fn issue -> IO.puts(format_issue_line(issue)) end)
    end
  end

  @doc "Print a workspace map. Mode-aware."
  @spec emit_workspace(map(), :text | :json) :: :ok
  def emit_workspace(ws, :json), do: IO.puts(Jason.encode!(ws))

  def emit_workspace(ws, :text) do
    IO.puts("workspace: #{ws["name"]}")
    IO.puts("  id:          #{ws["id"]}")
    IO.puts("  prefix:      #{ws["prefix"]}")

    if ws["description"] not in [nil, ""] do
      IO.puts("  description: #{ws["description"]}")
    end
  end

  @doc "Print a dependency map. Mode-aware."
  @spec emit_dependency(map(), :text | :json) :: :ok
  def emit_dependency(dep, :json), do: IO.puts(Jason.encode!(dep))

  def emit_dependency(dep, :text) do
    IO.puts("#{dep["from_issue_id"]} --#{dep["type"]}--> #{dep["to_issue_id"]}")
  end

  # ----- formatting primitives -----

  @doc """
  One-line summary used by `arb list` and `arb ready`. Format:

      <id>  [<status>] <priority?>  <title>

  Padding tuned to match the eye-friendly columns the Go `bd list` uses.
  """
  @spec format_issue_line(map()) :: String.t()
  def format_issue_line(issue) do
    id = String.pad_trailing(to_string(issue["id"] || ""), 10)
    status = "[#{issue["status"] || "?"}]" |> String.pad_trailing(14)
    priority = "P#{issue["priority"] || 0}"
    title = issue["title"] || ""
    "#{id} #{status} #{priority}  #{title}"
  end

  @doc """
  Multi-section detail view used by `arb show`. Sections (only emitted when
  the corresponding field is non-empty):

      ID:           <id>
      Title:        <title>
      Status:       <status>
      Priority:     <priority>
      Type:         <issue_type>
      Assignee:     <assignee>
      Workspace:    <workspace_id>
      Tracker:      <tracker_type>:<tracker_ref>
      Created:      <created_at>
      Updated:      <updated_at>
      Closed:       <closed_at>

      Description:
        <description>

      Acceptance:
        <acceptance>

      Notes:
        <notes>
  """
  @spec format_issue_detail(map()) :: String.t()
  def format_issue_detail(issue) do
    header =
      [
        {"ID", issue["id"]},
        {"Title", issue["title"]},
        {"Status", issue["status"]},
        {"Priority", issue["priority"]},
        {"Difficulty", difficulty_label(issue["difficulty"])},
        {"Type", issue["issue_type"]},
        {"Progress", child_progress_label(issue)},
        {"Auto-close", auto_close_label(issue)},
        {"Assignee", issue["assignee"]},
        {"Workspace", issue["workspace_id"]},
        {"Tracker", tracker_label(issue)},
        {"Target", issue["target_branch"]},
        {"Created", issue["created_at"]},
        {"Updated", issue["updated_at"]},
        {"Closed", issue["closed_at"]}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map(fn {k, v} -> "#{String.pad_trailing(k <> ":", 12)}#{v}" end)
      |> Enum.join("\n")

    sections =
      issue
      |> detail_sections()
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map(fn {k, v} -> "\n#{k}:\n  " <> indent(v) end)
      |> Enum.join("")

    header <> sections
  end

  # bd-5lc99r: for a `task`-type directive the deliverable IS the findings
  # summary in `notes`, so surface it first and labelled "Findings", with an
  # explicit placeholder when still blank so the Admiral can see the deliverable
  # is pending. Every other issue type keeps the standard ordering, where `notes`
  # is supporting context rather than the headline.
  defp detail_sections(%{"issue_type" => "task"} = issue) do
    findings = blank_to(issue["notes"], "(no findings recorded yet)")

    [
      {"Findings (notes)", findings},
      {"Description", issue["description"]},
      {"Acceptance", issue["acceptance"]},
      {"QA notes", issue["qa_notes"]},
      {"Deployment notes", issue["deployment_notes"]}
    ]
  end

  defp detail_sections(issue) do
    [
      {"Description", issue["description"]},
      {"Acceptance", issue["acceptance"]},
      {"Notes", issue["notes"]},
      {"QA notes", issue["qa_notes"]},
      {"Deployment notes", issue["deployment_notes"]}
    ]
  end

  defp blank_to(v, fallback) when v in [nil, ""], do: fallback
  defp blank_to(v, _fallback), do: v

  defp difficulty_label(nil), do: nil
  defp difficulty_label(n) when is_integer(n) and n in 0..4, do: "D#{n}"
  defp difficulty_label(other), do: to_string(other)

  # Child-progress rollup line for a parent task. Only shown when the task has
  # at least one `:parent_of` child (child_total > 0).
  defp child_progress_label(%{"child_total" => total, "child_closed" => closed})
       when is_integer(total) and total > 0 and is_integer(closed) do
    "#{closed}/#{total} children closed"
  end

  defp child_progress_label(_), do: nil

  # Only surface the auto-close flag when it is actually on; a plain task with
  # auto_close=false shouldn't clutter the detail view.
  defp auto_close_label(%{"auto_close" => true}), do: "yes (closes when all children done)"
  defp auto_close_label(_), do: nil

  defp tracker_label(%{"tracker_type" => nil}), do: nil
  defp tracker_label(%{"tracker_type" => "none"}), do: nil

  defp tracker_label(%{"tracker_type" => t, "tracker_ref" => ref}) when not is_nil(ref) do
    "#{t}:#{ref}"
  end

  defp tracker_label(%{"tracker_type" => t}), do: t
  defp tracker_label(_), do: nil

  defp indent(text), do: String.replace(text, "\n", "\n  ")

  # ----- error reporting -----

  @doc """
  Print an error message to stderr and halt the VM with a non-zero status.
  Optionally accepts a hint that's printed on a second line.
  """
  @spec die(String.t() | Client.Error.t()) :: no_return()
  def die(msg) when is_binary(msg) do
    IO.puts(:stderr, "arb: error: " <> msg)
    do_halt(1)
  end

  def die(%Client.Error{} = err) do
    IO.puts(:stderr, "arb: error: " <> err.message)

    if err.hint do
      IO.puts(:stderr, "       hint: " <> err.hint)
    end

    case err.body do
      %{"details" => details} when details != %{} ->
        IO.puts(:stderr, "      details: " <> Jason.encode!(details))

      _ ->
        :ok
    end

    do_halt(exit_code_for(err))
  end

  @spec die(String.t(), String.t()) :: no_return()
  def die(msg, hint) do
    IO.puts(:stderr, "arb: error: " <> msg)
    IO.puts(:stderr, "       hint: " <> hint)
    do_halt(1)
  end

  @doc """
  Halt the VM with a status code. Tests override this via
  `Process.put(:bd2_halt_strategy, :raise)` to capture exits without killing
  the test BEAM.
  """
  @spec halt(non_neg_integer()) :: no_return()
  def halt(code), do: do_halt(code)

  # Tests set :bd2_halt_strategy to :raise so they can capture exits via
  # rescue/catch without killing the BEAM. Production path calls System.halt/1.
  defp do_halt(code) do
    case Process.get(:bd2_halt_strategy, :system_halt) do
      :raise -> raise ArbiterCli.Output.Halt, code: code
      :system_halt -> System.halt(code)
    end
  end

  defp exit_code_for(%Client.Error{kind: :connection_refused}), do: 3
  defp exit_code_for(%Client.Error{kind: :http, status: 404}), do: 4
  defp exit_code_for(_), do: 1
end
