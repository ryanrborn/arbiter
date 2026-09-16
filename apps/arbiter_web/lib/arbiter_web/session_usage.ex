defmodule ArbiterWeb.SessionUsage do
  @moduledoc """
  The one place the dashboard turns coordinator sessions into cost and token
  figures (bd-9mrzti, lifted out of `ArbiterWeb.SessionIndexLive` by bd-a292yj
  so the session dock's info view reads it rather than growing a second copy).

  It is `Arbiter.Usage.summarize(by: :session)` — the same canonical rollup
  `arb usage --by session` uses — and **one query for a whole list**, never one
  per row: N running sessions cost one query per refresh tick, not N.

  The rollup keys on `session.provider_session_id`, because that is what
  `Arbiter.Usage.Event.session_id` holds (`Arbiter.Sessions.UsageIngest` writes
  rows keyed by the JSONL's own basename, not the Ash session id). A `--resume`
  or compaction rollover **replaces** that id rather than appending to it
  (`Session.record_provider_session/2`), so a rolled-over session's figure only
  ever reflects spend under its *current* provider id. Pre-rollover spend is
  real and ledgered, and reachable through `arb usage --by session`; this
  under-reports it, the same way `Arbiter.Sessions.usage_events/1` does.

  A session the ledger has no rows for yet reports `nil` rather than a zero, so
  callers can say "no usage data" instead of a silent `$0.00`.
  """

  alias Arbiter.Usage

  require Logger

  @type rollup :: map()

  @doc "Rollups for `sessions`, keyed by `provider_session_id`. One query."
  @spec for_sessions(Enumerable.t()) :: %{optional(String.t()) => rollup()}
  def for_sessions(sessions) do
    provider_ids =
      sessions
      |> Enum.map(& &1.provider_session_id)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case provider_ids do
      [] ->
        %{}

      _ids ->
        case Usage.summarize(by: :session, session_ids: provider_ids) do
          {:ok, rollups} ->
            Map.new(rollups, &{&1.group, &1})

          {:error, reason} ->
            Logger.error("SessionUsage: summarize failed: #{inspect(reason)}")
            %{}
        end
    end
  end

  @doc "The rollup for one session, or `nil` when the ledger has nothing for it."
  @spec for_session(map() | nil) :: rollup() | nil
  def for_session(nil), do: nil

  def for_session(session) do
    [session] |> for_sessions() |> Map.get(session.provider_session_id)
  end
end
