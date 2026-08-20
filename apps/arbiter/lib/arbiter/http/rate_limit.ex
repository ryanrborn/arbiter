defmodule Arbiter.Http.RateLimit do
  @moduledoc """
  Rate-limit hint parsing shared by the GitHub tracker and merger adapters.

  Both adapters need the same answer to the same question: given a
  rate-limited response, how long should the caller wait before trying again?
  GitHub answers it two different ways depending on which limit was hit —

    * `Retry-After` (seconds) accompanies the *secondary*/abuse limit, and
    * `x-ratelimit-reset` (unix epoch seconds) accompanies the *primary* quota
      limit, which never sends `Retry-After`.

  so the hint is "`Retry-After` if present, else time until `x-ratelimit-reset`,
  else none" (bd-1m8k7d, bd-2wilou).

  This module is the single copy of that logic; `Arbiter.Trackers.Github` and
  `Arbiter.Mergers.Github` both delegate to it rather than each parsing the
  headers themselves.
  """

  @rate_limited_statuses [403, 429]

  @doc """
  Milliseconds to wait before retrying a rate-limited response, or `nil`.

  `nil` for any status that isn't a rate limit, when `resp` is `nil` (call
  sites that never captured the full response simply get no hint), and when
  neither header is present or usable.
  """
  @spec retry_after_ms(integer() | nil, Req.Response.t() | nil) :: pos_integer() | nil
  def retry_after_ms(status, %Req.Response{} = resp) when status in @rate_limited_statuses do
    case retry_after_seconds(resp) do
      seconds when is_integer(seconds) -> seconds * 1_000
      nil -> reset_retry_after_ms(resp)
    end
  end

  def retry_after_ms(_status, _resp), do: nil

  @doc """
  The `Retry-After` header in seconds, or `nil` when absent/unparseable.

  Negative values are rejected: a bogus header must never turn into a negative
  backoff.
  """
  @spec retry_after_seconds(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after_seconds(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [v | _] ->
        case Integer.parse(v) do
          {seconds, _} when seconds >= 0 -> seconds
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Milliseconds until `x-ratelimit-reset` (unix epoch seconds), or `nil` when
  the header is absent, unparseable, or already in the past.
  """
  @spec reset_retry_after_ms(Req.Response.t()) :: pos_integer() | nil
  def reset_retry_after_ms(%Req.Response{} = resp) do
    with [v | _] <- Req.Response.get_header(resp, "x-ratelimit-reset"),
         {epoch, _} <- Integer.parse(v) do
      ms = (epoch - System.os_time(:second)) * 1_000
      if ms > 0, do: ms, else: nil
    else
      _ -> nil
    end
  end
end
