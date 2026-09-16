defmodule Arbiter.Sessions.DisplayName do
  @moduledoc """
  What to show for a session in a list or a title bar (bd-o2vtsz), and the one
  place both `ArbiterWeb.SessionIndexLive` and the session dock (its
  prerequisite epic) call to decide it.

  ## The ladder

  1. the operator-supplied name (`Session.name`), if one was given at launch;
  2. else the latest `ai-title` Claude Code has recorded in the session's own
     transcript JSONL — the CLI's own "derive one from context", and better
     than anything Arbiter would invent;
  3. else a short id.

  ## What this deliberately never reads

  Claude Code keeps a live per-session registry, `sessions/<pid>.json`
  (`Arbiter.Sessions.Naming`'s domain — process-liveness, not display), whose
  `name` field is **cwd-derived** whenever `nameSource` is `"derived"`. Every
  Arbiter session's cwd basename is the literal string `workspace`, so that
  name collides across the entire fleet (`workspace-a2`, `workspace-a3`, …)
  and would be worthless — worse than the short id it would replace. This
  module never reads that file at all; the operator name it does trust came
  from Arbiter's own `Session.name`, set once at launch time and passed
  through to `claude --name` so the two agree.

  ## Best-effort, by design

  A session's transcript can be mid-write, not yet created (no turn yet), or
  gone (an ended session whose scaffold was cleaned up). `ai_title/1` never
  raises: a missing, truncated, or malformed file just falls through to the
  next rung.
  """

  alias Arbiter.Sessions.Session
  alias Arbiter.Usage.ClaudeSessionFile

  @doc "The name to show for `session`: operator name → ai-title → short id."
  @spec resolve(Session.t()) :: String.t()
  def resolve(%Session{} = session) do
    operator_name(session) || ai_title(session) || short_id(session.id)
  end

  @doc """
  The latest `ai-title` Claude Code has recorded for `session`'s transcript,
  or `nil` — no `provider_session_id` yet (pre-first-turn), no matching JSONL
  under the session's `config_dir`, no `ai-title` record in it yet, or the
  file could not be read/parsed. Never raises.
  """
  @spec ai_title(Session.t()) :: String.t() | nil
  def ai_title(%Session{config_dir: config_dir, provider_session_id: provider_session_id}) do
    case ClaudeSessionFile.locate(config_dir, provider_session_id) do
      {:ok, path} -> latest_ai_title(path)
      :not_found -> nil
    end
  end

  @doc "The first segment of a session UUID — enough to tell two apart on screen."
  @spec short_id(String.t()) :: String.t()
  def short_id(id) when is_binary(id), do: id |> String.split("-") |> hd()

  defp operator_name(%Session{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp operator_name(%Session{}), do: nil

  # Rewritten as the session goes (bd-o2vtsz's ticket: "rewritten as the
  # session goes"), so the newest record in the file wins — a plain fold over
  # the whole thing rather than stopping at the first match.
  defp latest_ai_title(path) do
    path
    |> File.stream!()
    |> Enum.reduce(nil, fn line, latest ->
      case parse_ai_title(line) do
        nil -> latest
        title -> title
      end
    end)
  rescue
    _ -> nil
  end

  defp parse_ai_title(line) do
    if String.contains?(line, "\"ai-title\"") do
      case Jason.decode(line) do
        {:ok, %{"type" => "ai-title", "aiTitle" => title}} when is_binary(title) -> title
        _ -> nil
      end
    end
  end
end
