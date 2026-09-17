defmodule Arbiter.Sessions.BridgeVerification do
  @moduledoc """
  Poll a `--remote-control` session's JSONL for the `bridge-session` record
  that proves Remote Control actually came up (§8.3 of
  `docs/browser-hosted-coordinator-sessions.md`, phase 8).

  ## Why a poll, not a flag

  The §8.3 spike found `--remote-control` under a workspace OAuth token
  starts **normally** — the CLI runs, a real turn completes — and never
  establishes a bridge at all: zero `bridge-session` records, no `bridge*`
  keys in `.claude.json`, no `oauthAccount`. Passing the flag and getting a
  clean exit code proves nothing; the bridge is a claude.ai-side handshake
  that either lands in the JSONL within a few seconds or never does. So this
  module never trusts the launch, only what the transcript shows.

  ## What "present" means

  Any line in any `*.jsonl` under `<config_dir>/projects/*/` that decodes as
  JSON with `"type": "bridge-session"`. That is deliberately looser than
  matching the *current* provider session id: `provider_session_id` is
  nullable at launch (`Arbiter.Sessions.Stream`'s `discover_usage_source/1`
  doc explains why), and a bridge record appearing in *some* file under this
  session's own isolated config dir is exactly as strong a signal — nothing
  else writes into it.
  """

  require Logger

  @default_timeout_ms 15_000
  @default_poll_interval_ms 500

  @doc """
  Poll `config_dir` for a `bridge-session` record.

  Returns `:ok` as soon as one is found, `{:error, :bridge_unavailable}` once
  `:timeout_ms` (default #{@default_timeout_ms}) has elapsed without one.
  `:poll_interval_ms` (default #{@default_poll_interval_ms}) is the wait
  between reads — both exist as options so a test can drive this
  deterministically against a fixture rather than waiting on real wall time.
  """
  @spec verify(String.t(), keyword()) :: :ok | {:error, :bridge_unavailable}
  def verify(config_dir, opts \\ []) when is_binary(config_dir) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll(config_dir, deadline, poll_interval_ms)
  end

  @doc """
  A single, non-blocking check for a `bridge-session` record — the same test
  `verify/2` polls with, exposed for a caller that wants a one-shot answer
  instead of waiting out a timeout (bd-cdretj round 2: the session dock
  re-checks this on `open` to clear a stale `:unavailable` once an operator
  has since retried `/remote-control` by hand).
  """
  @spec present?(String.t()) :: boolean()
  def present?(config_dir) when is_binary(config_dir), do: bridge_session_present?(config_dir)

  defp poll(config_dir, deadline, poll_interval_ms) do
    if bridge_session_present?(config_dir) do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        {:error, :bridge_unavailable}
      else
        Process.sleep(min(poll_interval_ms, remaining))
        poll(config_dir, deadline, poll_interval_ms)
      end
    end
  end

  defp bridge_session_present?(config_dir) do
    config_dir
    |> Path.join("projects/*/*.jsonl")
    |> Path.wildcard()
    |> Enum.any?(&file_has_bridge_session?/1)
  end

  defp file_has_bridge_session?(path) do
    path
    |> File.stream!()
    |> Enum.any?(&bridge_session_line?/1)
  rescue
    e ->
      Logger.warning("Sessions.BridgeVerification: cannot read #{path}: #{Exception.message(e)}")
      false
  end

  defp bridge_session_line?(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "bridge-session"}} -> true
      _ -> false
    end
  end
end
