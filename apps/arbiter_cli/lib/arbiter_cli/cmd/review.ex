defmodule ArbiterCli.Cmd.Review do
  @moduledoc """
  `arb review <task-id> [--repo <repo>] [--model <name>] [--json]` — dispatch a
  review-only worker against the PR/MR linked to a task.

  `arb review --pr <url|number> [--repo <repo>] [--workspace <name|id>] [--json]`
  — review an **external / non-arbiter PR** (one the fleet never opened, e.g. a
  coworker's PR): no task, no branch required.

  POSTs to `/api/workers/review`.

  ## Task review (positional `<task-id>`)

  The server transitions the task to `:in_progress`, attaches the
  `Arbiter.Workflows.CodeReview` workflow, **skips** worktree provisioning and
  per-task branch creation, and spawns a Claude subprocess with a review prompt.
  The reviewer reads the PR/MR diff, posts findings + a verdict via the
  configured tracker, and prints `arb done`.

  ## External PR review (`--pr`)

  Constructs an `mr_ref` for the given PR through the workspace's MR-provider
  adapter (the github/gitlab merger — NOT the issue tracker) and runs
  `CodeReview` in `:adapter` mode: read the diff, post per-finding inline
  comments, submit a single verdict — all on the PR itself, with no arbiter task
  or branch. `--pr` accepts a forge URL, an `owner/repo#N` slug, or a bare
  number (with `--repo` so a number can be resolved to owner/repo via the
  checkout's `origin` remote).

  `arb review --transcript <record-id> [--tail N] [--no-prompt] [--json]` —
  read back the durable corpus of one already-dispatched **external** review
  (bd-7efini): the prompt its reviewer was given, the tools it used and what
  they returned, and the transcript itself. `arb worker log`'s counterpart for
  a review, which — not being task-linked — has no run to look up. GETs
  `/api/external_reviews/:id/transcript`. Record ids come from
  `arb review --pr` output or the `/reviews` page.

  ## Flags

    --pr <url|number>  Review an external PR/MR (no task id needed).
    --repo <repo>      Local checkout. For a task review, the cwd the reviewer
                       runs in. For `--pr`, used to resolve owner/repo for a
                       bare PR number.
    --workspace <ref>  (`--pr` only) Workspace name/id whose MR provider to use;
                       defaults to the installation's sole/`default` workspace.
    --model <name>     (task review only) one-shot model override
                       (`haiku|sonnet|opus`).
    --transcript <id>  Read one external review's persisted corpus instead of
                       dispatching anything.
    --tail <n>         (`--transcript` only) only the last N transcript lines.
    --no-prompt        (`--transcript` only) omit the (large) review prompt.
    --json             emit JSON instead of human-readable text

  ## What this does NOT do

  Reviews never push, merge, or modify a branch. Adding a `--push` flag
  would defeat the purpose — to dispatch authored work, use `arb dispatch`.
  """

  alias ArbiterCli.{Client, Output}

  @switches [
    json: :boolean,
    repo: :string,
    model: :string,
    pr: :string,
    workspace: :string,
    transcript: :string,
    tail: :integer,
    prompt: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
      mode = if opts[:json], do: :json, else: :text

      cond do
        opts[:transcript] not in [nil, ""] -> run_transcript(opts, mode)
        opts[:pr] not in [nil, ""] -> run_external(opts, mode)
        true -> run_task(opts, rest, mode)
      end
    end
  end

  # External / non-arbiter PR review — no task id, keyed on --pr.
  defp run_external(opts, mode) do
    body =
      %{"pr" => opts[:pr]}
      |> maybe_put("repo", opts[:repo])
      |> maybe_put("workspace", opts[:workspace])

    case Client.post("/api/workers/review", body) do
      {:ok, payload} -> emit_external(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp run_task(opts, rest, mode) do
    task_id =
      case rest do
        [id] ->
          id

        [] ->
          Output.die(
            "review requires a task id (e.g. `arb review bd-4b39bf`) or `--pr <url|number>`"
          )

        _ ->
          Output.die("review takes a single positional argument: <task-id>")
      end

    body =
      %{"task_id" => task_id}
      |> maybe_put("repo", opts[:repo])
      |> maybe_put("model", opts[:model])

    case Client.post("/api/workers/review", body) do
      {:ok, payload} -> emit(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  # Read-back path: no dispatch, just this review's persisted corpus.
  defp run_transcript(opts, mode) do
    query =
      []
      |> then(fn q -> if opts[:tail], do: [{"tail", opts[:tail]} | q], else: q end)
      |> then(fn q ->
        if opts[:prompt] == false, do: [{"include_prompt", "false"} | q], else: q
      end)

    path =
      "/api/external_reviews/#{opts[:transcript]}/transcript" <>
        if query == [], do: "", else: "?" <> URI.encode_query(query)

    case Client.get(path) do
      {:ok, payload} -> emit_transcript(payload, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_transcript(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_transcript(payload, :text) do
    data = payload["data"] || payload

    IO.puts("Review #{data["record_id"]} — #{data["pr_ref"]} (#{data["status"]})")
    IO.puts("  Model:    #{data["model"] || "—"}")
    IO.puts("  Path:     #{data["path"]}")

    if data["exists"] || data["prompt_exists"] do
      emit_transcript_prompt(data["prompt"])
      emit_transcript_tools(data)
      emit_transcript_lines(data)
    else
      IO.puts("  (no transcript captured for this review)")
    end
  end

  defp emit_transcript_prompt(nil), do: :ok

  defp emit_transcript_prompt(prompt) do
    IO.puts("\n--- prompt ---")
    IO.puts(prompt)
  end

  defp emit_transcript_tools(data) do
    tools = data["tools_used"] || []

    if tools != [] do
      summary = Enum.map_join(tools, ", ", &"#{&1["name"]} ×#{&1["count"]}")
      IO.puts("\n--- tools (#{data["tool_use_count"]}) ---")
      IO.puts(summary)

      for tool_use <- data["tool_uses"] || [] do
        IO.puts("  #{tool_use["name"]} #{Jason.encode!(tool_use["input"] || %{})}")

        case tool_use["result"] do
          r when is_binary(r) and r != "" -> IO.puts("    → #{first_line(r)}")
          _ -> :ok
        end
      end
    end
  end

  defp emit_transcript_lines(data) do
    lines = data["lines"] || []

    if lines != [] do
      shown = if data["truncated"], do: " (last #{length(lines)})", else: ""
      IO.puts("\n--- transcript: #{data["line_count"]} lines#{shown} ---")
      Enum.each(lines, &IO.puts/1)
    end
  end

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit_external(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit_external(payload, :text) do
    data = payload["data"] || payload

    IO.puts("External review dispatched:")
    IO.puts("  PR:       #{data["pr"]}")
    IO.puts("  Ref:      #{data["mr_ref"]}")
    IO.puts("  Provider: #{data["strategy"]}")

    case data["link"] do
      link when is_binary(link) and link != "" -> IO.puts("  Link:     #{link}")
      _ -> :ok
    end

    IO.puts("  Findings + a verdict will be posted to the PR.")
  end

  defp emit(payload, :json), do: IO.puts(Jason.encode!(payload))

  defp emit(payload, :text) do
    task = payload["task"] || %{}
    worker = payload["worker"] || %{}
    machine = payload["machine"] || %{}

    IO.puts("Review dispatched:")
    IO.puts("  Issue:     #{task["id"]} — #{task["title"]}")
    IO.puts("  Status:   #{task["status"]}")
    IO.puts("  Worker:  #{worker["pid"]}")
    IO.puts("  Machine:  #{machine["id"]} #{machine["pid"]}")

    case payload["claude_started"] do
      true -> IO.puts("  Claude:   started")
      _ -> :ok
    end
  end
end
