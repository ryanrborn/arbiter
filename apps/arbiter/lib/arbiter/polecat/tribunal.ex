defmodule Arbiter.Polecat.Tribunal do
  @moduledoc """
  The review gate ("Tribunal") that sits between an acolyte's `arb done` and the
  merger. A standing order: an acolyte must not merge its own work — a separate
  reviewer mind code-reviews the diff first.

  ## Where it fits

  When an acolyte signals done (`arb done`), the author `Arbiter.Polecat` checks
  whether its workspace requires review (`Workspace.review_required?/1`). If so it
  parks at `:awaiting_tribunal` and spawns a Tribunal **instead of** calling the
  merger. The Tribunal then:

    1. Spawns a **distinct** reviewer acolyte — a second `Arbiter.Polecat` with a
       `#review`-suffixed bead id and its own `Arbiter.Polecat.ClaudeSession`,
       running in the same worktree. A different process = a different Claude
       invocation = a different mind (no self-grading).
    2. Hands the reviewer the bead's acceptance criteria + description and asks it
       to review the branch diff for correctness / regressions, **without booting
       the app** (the second-instance hazard, bd-9rouwh — the reviewer only reads
       the diff).
    3. Captures the reviewer's stdout (via the polecat output PubSub topic) and
       waits for it to finish.
    4. Parses a structured verdict from the transcript — a sentinel line
       `VERDICT: APPROVE` or `VERDICT: REQUEST_CHANGES` plus findings.
    5. Reports the verdict back to the author polecat
       (`Arbiter.Polecat.tribunal_verdict/2`):
         * APPROVE → the author proceeds to the merger (`do_open_mr`).
         * REQUEST_CHANGES (or an inconclusive / timed-out review) → the author
           parks the bead with the findings and escalates to the Admiral; the
           branch is **not** merged.

  This is **Stage 1** (the gate MVP). The revise-and-re-review loop (Stage 2) and
  same-mind continuity (Stage 3) are separate beads; here the Tribunal runs a
  single review pass and a non-approve verdict escalates rather than looping.

  ## Verdict protocol

  The reviewer emits, on its own line:

      VERDICT: APPROVE
      VERDICT: REQUEST_CHANGES

  Case-insensitive; surrounding whitespace tolerated. Everything from the verdict
  line onward is captured as the findings. If no recognizable verdict appears (a
  crashed or silent reviewer), the verdict is `:no_verdict` and the author treats
  it as inconclusive — the safe default is "do not merge".

  ## Testing

  `start/1` accepts a `:command` argv (forwarded to `ClaudeSession`) so tests can
  spawn an echo script that prints a canned verdict instead of invoking real
  Claude. `parse_verdict/1` is a pure function and is unit-tested directly.
  """

  use GenServer
  require Logger

  alias Arbiter.Beads.Issue
  alias Arbiter.Polecat
  alias Arbiter.Polecat.ClaudeSession

  # Default ceiling on how long we wait for the reviewer before escalating as a
  # timed-out review. Real Claude reviews can take a while; tests override this.
  @default_timeout_ms 20 * 60 * 1000

  @verdict_approve ~r/^\s*VERDICT:\s*APPROVE\b/im
  @verdict_request_changes ~r/^\s*VERDICT:\s*(REQUEST_CHANGES|REJECT)\b/im

  @type verdict ::
          {:approve, String.t()} | {:request_changes, String.t()} | :no_verdict

  @type opt ::
          {:author, pid()}
          | {:bead_id, String.t()}
          | {:workspace_id, String.t() | nil}
          | {:rig, String.t()}
          | {:worktree_path, String.t() | nil}
          | {:branch, String.t()}
          | {:target_branch, String.t()}
          | {:command, [String.t()] | nil}
          | {:timeout_ms, non_neg_integer()}

  @doc """
  Start a Tribunal under `Arbiter.Polecat.Supervisor`.

  Required opts: `:author` (the author polecat pid to report back to),
  `:bead_id`, `:rig`, `:branch`. Optional: `:workspace_id`, `:worktree_path`,
  `:target_branch` (default `"main"`), `:command` (test override for the reviewer
  argv), `:timeout_ms`.
  """
  @spec start([opt()]) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Polecat.Supervisor, {__MODULE__, opts})
  end

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  The bead id used for the reviewer acolyte — the author bead id with a
  `#review` suffix so it registers as a distinct polecat and records its own run
  row without colliding with the author.
  """
  @spec reviewer_bead_id(String.t()) :: String.t()
  def reviewer_bead_id(bead_id) when is_binary(bead_id), do: bead_id <> "#review"

  # ---- verdict parsing (pure) --------------------------------------------

  @doc """
  Parse a reviewer's output lines into a verdict.

  Returns `{:approve, findings}`, `{:request_changes, findings}`, or
  `:no_verdict` when no recognizable sentinel is present. `findings` is the
  transcript from the verdict line onward (trimmed), so the author can persist /
  escalate the reviewer's reasoning verbatim.
  """
  @spec parse_verdict([String.t()]) :: verdict()
  def parse_verdict(lines) when is_list(lines) do
    text = Enum.join(lines, "\n")

    cond do
      Regex.match?(@verdict_approve, text) ->
        {:approve, findings_from(text, @verdict_approve)}

      Regex.match?(@verdict_request_changes, text) ->
        {:request_changes, findings_from(text, @verdict_request_changes)}

      true ->
        :no_verdict
    end
  end

  # Findings = everything from the matched verdict line to the end, trimmed.
  # Falls back to the whole transcript if the index can't be located.
  defp findings_from(text, regex) do
    case Regex.run(regex, text, return: :index) do
      [{start, _len} | _] ->
        text |> binary_part(start, byte_size(text) - start) |> String.trim()

      _ ->
        String.trim(text)
    end
  end

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    author = Keyword.fetch!(opts, :author)
    bead_id = Keyword.fetch!(opts, :bead_id)

    state = %{
      author: author,
      bead_id: bead_id,
      review_id: reviewer_bead_id(bead_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      rig: Keyword.get(opts, :rig, "unknown"),
      worktree_path: Keyword.get(opts, :worktree_path),
      branch: Keyword.fetch!(opts, :branch),
      target_branch: Keyword.get(opts, :target_branch, "main"),
      command: Keyword.get(opts, :command),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      reviewer_pid: nil,
      lines: [],
      reported?: false
    }

    Process.monitor(author)
    {:ok, state, {:continue, :spawn_reviewer}}
  end

  @impl true
  def handle_continue(:spawn_reviewer, state) do
    # Subscribe BEFORE spawning so we can't miss the reviewer's first output
    # lines or its exit signal (the subprocess may finish almost immediately —
    # e.g. a fast reviewer or a test fixture). The topic is known from the
    # review_id alone, so subscribing ahead of the port open is safe.
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "polecat:" <> state.review_id)

    case spawn_reviewer(state) do
      {:ok, reviewer_pid} ->
        Process.send_after(self(), :timeout, state.timeout_ms)
        {:noreply, %{state | reviewer_pid: reviewer_pid}}

      {:error, reason} ->
        Logger.warning(
          "Tribunal: failed to spawn reviewer for bead=#{state.bead_id}: #{inspect(reason)}"
        )

        report(
          state,
          {:request_changes, "Tribunal could not spawn a reviewer: #{inspect(reason)}"}
        )

        {:stop, :normal, %{state | reported?: true}}
    end
  end

  # A Tribunal is NOT a polecat, but it lives under Arbiter.Polecat.Supervisor —
  # so a stray enumeration (dashboard / list_children) could probe it with the
  # polecat `:snapshot` call. Answer gracefully instead of crashing the gate and
  # stranding the author at :awaiting_tribunal. See bd-2y0gd5.
  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot(state), state}
  end

  @impl true
  def handle_info({:polecat_output, _id, line}, state) do
    {:noreply, %{state | lines: [line | state.lines]}}
  end

  # The reviewer's subprocess exited — its transcript is complete. Parse and
  # report. (The reviewer polecat also self-completes on its own `arb done`;
  # either way the exit is our reliable "transcript done" signal.)
  def handle_info({:polecat_exited, _id, _status}, state) do
    {:stop, :normal, finish(state)}
  end

  def handle_info(:timeout, %{reported?: true} = state), do: {:noreply, state}

  def handle_info(:timeout, state) do
    Logger.warning("Tribunal: reviewer timed out for bead=#{state.bead_id}")

    report(
      state,
      {:request_changes,
       "Tribunal review timed out after #{div(state.timeout_ms, 1000)}s with no verdict."}
    )

    {:stop, :normal, %{state | reported?: true}}
  end

  # Author died before we could report — nothing to do.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{author: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Stop the reviewer polecat if it's still alive (e.g. on timeout).
    if is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid) do
      safe(fn -> Polecat.stop(state.reviewer_pid, :normal) end)
    end

    :ok
  end

  # ---- internals ----------------------------------------------------------

  # Parse the captured transcript and report the verdict to the author exactly
  # once.
  defp finish(%{reported?: true} = state), do: state

  defp finish(state) do
    verdict = parse_verdict(Enum.reverse(state.lines))
    report(state, verdict)
    %{state | reported?: true}
  end

  # Report the verdict to the author exactly once. An inconclusive review
  # (`:no_verdict`) is forwarded as such; the author's safe default for it is to
  # escalate without merging.
  defp report(state, verdict) do
    safe(fn -> Polecat.tribunal_verdict(state.author, normalize_verdict(verdict)) end)
    :ok
  end

  defp normalize_verdict({:approve, _} = v), do: v
  defp normalize_verdict({:request_changes, _} = v), do: v

  defp normalize_verdict(:no_verdict),
    do: {:no_verdict, "Reviewer produced no parseable VERDICT line."}

  defp normalize_verdict({:no_verdict, _findings} = v), do: v

  # Start the reviewer as a distinct polecat + claude session. The reviewer gets
  # workspace_id: nil so its completion stays silent — no Admiral notification,
  # no Refinery pickup for the synthetic `#review` bead — while still recording
  # its own run row.
  defp spawn_reviewer(state) do
    with {:ok, reviewer_pid} <- start_reviewer_polecat(state),
         :ok <- start_reviewer_session(state, reviewer_pid) do
      _ = Polecat.advance(reviewer_pid, :reviewing)
      {:ok, reviewer_pid}
    end
  end

  defp start_reviewer_polecat(state) do
    case Polecat.start(
           bead_id: state.review_id,
           rig: state.rig,
           workspace_id: nil,
           meta: %{role: :reviewer, reviews: state.bead_id}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:reviewer_start_failed, reason}}
    end
  end

  defp start_reviewer_session(state, reviewer_pid) do
    session_opts =
      [owner: reviewer_pid, worktree_path: state.worktree_path] ++
        case state.command do
          nil -> [prompt: review_prompt(state)]
          cmd when is_list(cmd) -> [command: cmd]
        end

    case ClaudeSession.start(session_opts) do
      {:ok, _port} -> :ok
      {:error, reason} -> {:error, {:reviewer_session_failed, reason}}
    end
  end

  # Minimal snapshot for a Tribunal probed as if it were a polecat. The Tribunal
  # is a review gate, not an acolyte; this exists only so an accidental
  # :snapshot call gets a sane reply rather than crashing it. See bd-2y0gd5.
  defp snapshot(state) do
    %{
      bead_id: state.bead_id,
      review_id: state.review_id,
      status: :reviewing,
      current_step: "tribunal",
      rig: state.rig,
      role: :tribunal,
      reviewer_alive: is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid)
    }
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Build the reviewer's prompt: the bead's acceptance criteria + description, the
  branch under review, the verdict protocol, and the hard no-boot constraint.
  Public so it can be inspected in tests.
  """
  @spec review_prompt(map()) :: String.t()
  def review_prompt(state) do
    bead = load_bead(state.bead_id)

    """
    You are a REVIEWER acolyte — a Tribunal. You did NOT write this code; a
    different acolyte did. Your job is to code-review its work before it merges.
    You must reach an independent verdict — do not rubber-stamp.

    Bead under review: #{state.bead_id}
    Title: #{bead.title}

    Description:
    #{bead.description}

    Acceptance criteria:
    #{bead.acceptance}

    The work is on branch `#{state.branch}`, cut from `#{state.target_branch}`.
    Review ONLY the diff. Inspect it with, e.g.:

        git diff #{state.target_branch}...HEAD
        git log --oneline #{state.target_branch}..HEAD

    Judge the change against the acceptance criteria AND for correctness,
    regressions, and obvious defects.

    *** ABSOLUTE RULE: DO NOT boot the app. No `mix phx.server`, no `iex -S mix`,
    no `mix run`. Running a second app instance is hazardous. You review the diff
    by reading it — you do not run the application. (Reading files and running
    `git` is fine.)

    When you have decided, print your verdict on its own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    Follow the verdict with your findings: for REQUEST_CHANGES list each problem
    with its severity, location, and a suggested fix. Then print, on a line by
    itself:

        arb done
    """
  end

  defp load_bead(bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, %Issue{} = bead} ->
        %{
          title: bead.title || "(untitled)",
          description: bead.description || "(none)",
          acceptance: bead.acceptance || "(none)"
        }

      _ ->
        %{title: "(unknown)", description: "(none)", acceptance: "(none)"}
    end
  rescue
    _ -> %{title: "(unknown)", description: "(none)", acceptance: "(none)"}
  end
end
