defmodule Arbiter.Usage.CodexSessionFile do
  @moduledoc """
  Locate and read a Codex CLI probe's on-disk rollout JSONL, to backfill a
  `usage_events` row whose live capture (`Arbiter.Usage.Probe`) landed with
  `tokens_in`/`tokens_out: nil` before bd-96mn8i taught `Probe.parse/1`
  codex's `turn.completed` shape.

  ## On-disk layout (confirmed against installed codex-cli 0.153.4)

  The CLI writes one file per session at:

      $CODEX_HOME/sessions/YYYY/MM/DD/rollout-<iso-ish-timestamp>-<session-id>.jsonl

  where `$CODEX_HOME` defaults to `~/.codex` when unset (the CLI's own
  default, mirrored here rather than reimplemented — see
  `Arbiter.Agents.Codex.Config`'s moduledoc for the auth side of the same
  convention). The directory triple is the UTC date the CLI opened the file,
  matching the `session_meta` line's own `timestamp` field.

  The first line of every file is a `session_meta` event carrying the wall
  clock the CLI process started:

      {"type":"session_meta","payload":{"session_id":"...","timestamp":"2026-09-21T16:23:15.991Z",...}}

  and — for a probe round-trip specifically — later lines carry the
  cumulative token totals as `token_count` events:

      {"type":"token_count","info":{"total_token_usage":{"input_tokens":11734,"cached_input_tokens":8960,"output_tokens":5,...},...}}

  `Arbiter.Agents.Codex.Stream.usage_fields/2` already knows this exact shape
  (it is the same `token_count` clause the *live* stream parser reads for
  pre-0.142.5 CLIs) — this module only adds the "find the right file for a
  ledger row" step and reuses that parser rather than re-deriving the field
  mapping a second time.

  ## Matching a `usage_events` row to a file

  A probe row carries no session id (per-dispatch probes are one-shot,
  `Arbiter.Usage.Probe.record/3` only fills `session_id` when the CLI
  reported one, and codex's `turn.completed` payload does not), so the only
  correlation available is time: a row's `occurred_at` is when `record/3`
  ran, just after the probe process exited, and `occurred_at - duration_ms`
  is (approximately) when the CLI process started — which is exactly what a
  rollout's `session_meta.timestamp` records. `find_for_probe/3` globs the
  UTC day directory (and the previous day, for a probe that straddled
  midnight) and picks the file whose `session_meta` timestamp is closest to
  that estimate, within a tolerance.
  """

  require Logger

  @type totals :: %{
          tokens_in: integer() | nil,
          tokens_out: integer() | nil,
          cache_read_tokens: integer() | nil,
          raw: map() | nil
        }

  @doc """
  The root directory the codex CLI writes session rollouts under.

  `$CODEX_HOME` when set (matching the CLI's own resolution), else
  `~/.codex`.
  """
  @spec home_dir() :: String.t()
  def home_dir do
    case System.get_env("CODEX_HOME") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(System.user_home!(), ".codex")
    end
  end

  @doc "The `sessions/` directory under `home_dir/0`."
  @spec sessions_dir() :: String.t()
  def sessions_dir, do: Path.join(home_dir(), "sessions")

  @doc """
  Every rollout `.jsonl` file under the UTC day directory for `date`, rooted
  at `sessions_dir` (defaults to `sessions_dir/0`; overridable so tests don't
  have to mutate `$CODEX_HOME` process-globally).
  Empty when the day has no rollouts (or the sessions dir doesn't exist).
  """
  @spec candidates_for_date(Date.t(), String.t()) :: [String.t()]
  def candidates_for_date(%Date{} = date, sessions_dir \\ sessions_dir()) do
    dir =
      Path.join([
        sessions_dir,
        pad4(date.year),
        pad2(date.month),
        pad2(date.day)
      ])

    Path.wildcard(Path.join(dir, "*.jsonl"))
  end

  @doc """
  Find the rollout file whose `session_meta.timestamp` is closest to a
  probe's estimated start time, within `tolerance_ms` (default 5000).

  `occurred_at` is the ledger row's own timestamp (when `record/3` ran,
  just after the probe exited) and `duration_ms` is the row's recorded
  duration; their difference estimates the CLI process's start, which is
  what `session_meta.timestamp` records. Returns `{:ok, path}` or
  `:not_found`.

  `:sessions_dir` in `opts` overrides `sessions_dir/0`, for tests.
  """
  @spec find_for_probe(DateTime.t(), integer() | nil, integer(), keyword()) ::
          {:ok, String.t()} | :not_found
  def find_for_probe(occurred_at, duration_ms, tolerance_ms \\ 5_000, opts \\ [])

  def find_for_probe(%DateTime{} = occurred_at, duration_ms, tolerance_ms, opts) do
    sessions_dir = Keyword.get(opts, :sessions_dir, sessions_dir())

    start_estimate =
      if is_integer(duration_ms),
        do: DateTime.add(occurred_at, -duration_ms, :millisecond),
        else: occurred_at

    [DateTime.to_date(start_estimate), DateTime.to_date(occurred_at)]
    |> Enum.uniq()
    |> Enum.flat_map(&candidates_for_date(&1, sessions_dir))
    |> Enum.uniq()
    |> Enum.map(&{&1, session_meta_timestamp(&1)})
    |> Enum.filter(fn {_path, ts} -> match?(%DateTime{}, ts) end)
    |> Enum.map(fn {path, ts} -> {path, abs(DateTime.diff(ts, start_estimate, :millisecond))} end)
    |> Enum.filter(fn {_path, diff_ms} -> diff_ms <= tolerance_ms end)
    |> Enum.min_by(fn {_path, diff_ms} -> diff_ms end, fn -> nil end)
    |> case do
      nil -> :not_found
      {path, _diff_ms} -> {:ok, path}
    end
  end

  @doc """
  Read a rollout file's `session_meta.timestamp` (the first line). `:error`
  when the file is missing, unreadable, or its first line doesn't decode to
  a `session_meta` event with a parseable timestamp.
  """
  @spec session_meta_timestamp(String.t()) :: DateTime.t() | :error
  def session_meta_timestamp(path) do
    with {:ok, line} <- first_line(path),
         {:ok, %{"type" => "session_meta", "payload" => %{"timestamp" => ts}}} <- decode(line),
         {:ok, dt, _offset} <- DateTime.from_iso8601(ts) do
      dt
    else
      _ -> :error
    end
  end

  @doc """
  Read the final `token_count` event's totals out of a rollout file, via
  `Arbiter.Agents.Codex.Stream.usage_fields/2` — the same field mapping the
  live stream parser uses. Later `token_count` lines are cumulative (see the
  moduledoc), so the last one in the file is the session's total. Returns
  `{:ok, totals}` (all fields `nil` when the file carries no `token_count`
  line at all) or `{:error, reason}` when the file itself can't be read.
  """
  @spec read_totals(String.t()) :: {:ok, totals()} | {:error, term()}
  def read_totals(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          {:ok, last_token_count(io)}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- internals ---------------------------------------------------------

  defp last_token_count(io) do
    io
    |> IO.stream(:line)
    |> Enum.reduce(%{tokens_in: nil, tokens_out: nil, cache_read_tokens: nil, raw: nil}, fn line,
                                                                                            acc ->
      case decode(line) do
        {:ok, event} ->
          case token_count_payload(event) do
            %{} = payload ->
              fields = Arbiter.Agents.Codex.Stream.usage_fields(payload, nil)

              %{
                tokens_in: Map.get(fields, :tokens_in, acc.tokens_in),
                tokens_out: Map.get(fields, :tokens_out, acc.tokens_out),
                cache_read_tokens: Map.get(fields, :cache_read_tokens, acc.cache_read_tokens),
                raw: Map.get(fields, :raw, acc.raw)
              }

            nil ->
              acc
          end

        :error ->
          acc
      end
    end)
  end

  # Every line on disk is wrapped in an envelope the live stream never sees:
  # `{"timestamp":..,"ordinal":..,"type":"event_msg","payload":{...the actual
  # event...}}` (confirmed live, installed codex-cli 0.153.4, against a real
  # rollout under `~/.codex/sessions/`; `session_meta` is the one exception —
  # it is *not* `event_msg`-wrapped, its own `type` is `session_meta` at the
  # top level, which `session_meta_timestamp/1` already relies on). Unwrap to
  # the inner event before handing it to `Codex.Stream.usage_fields/2`, which
  # knows the *unwrapped* `token_count` shape (it reads the live `--json`
  # stream, which carries no envelope at all).
  defp token_count_payload(%{"type" => "token_count"} = event), do: event

  defp token_count_payload(%{
         "type" => "event_msg",
         "payload" => %{"type" => "token_count"} = payload
       }),
       do: payload

  defp token_count_payload(_event), do: nil

  defp first_line(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.read(io, :line) do
            :eof -> {:error, :empty}
            {:error, reason} -> {:error, reason}
            line -> {:ok, line}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp pad4(n), do: n |> Integer.to_string() |> String.pad_leading(4, "0")
  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
