defmodule Arbiter.Quota.Gate.Snapshot do
  @moduledoc """
  Provider-neutral view of a quota snapshot, for `Arbiter.Quota.Gate` (bd-2mpo3f).

  Each provider persists its quota state in its own table with its own field
  names — `AnthropicQuota` has `utilization_5h` / `status_5h` / `reset_5h_at`,
  `CodexQuota` has `session_used_percent` / `limit_reached` / `session_reset_at`,
  `GoogleQuota` has a single representative `used_percent` / `reset_at`. The gate
  needs the same three things from all of them, so `normalize/1` projects each
  row onto this struct and the gate reasons only about:

    * `utilization` — the primary window's usage as a `0.0..1.0` fraction
      (Codex/Google report 0–100 percents; those are rescaled here).
    * `status` — the provider's own verdict. `"allowed"` (or `nil`) means
      plan-allowed; anything else is past-plan and holds. Codex's
      `limit_reached: true` maps to `"limit_reached"`; Google reports no status.
    * `reset_at` / `captured_at` — the staleness inputs (`Gate.stale?/1`).

  Only the **primary** window is projected, matching the Anthropic gating this
  generalizes (which keys on the 5h window and ignores the 7d one). Codex's
  weekly window and Google's non-representative models are carried on the row
  for the dashboard but are deliberately not gating inputs here.

  `overage_status` is Anthropic-only (there is no paid-overage passthrough for
  Codex or Google); it stays `nil` for those providers, so `Gate.in_overage?/2`
  falls back to the past-plan `status` signal for them.

  `normalize/1` returns `nil` for `nil` and for anything it does not recognize —
  the gate's fail-open contract: an unknown or missing snapshot never blocks a
  dispatch.
  """

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.GoogleQuota

  @type t :: %__MODULE__{
          provider: String.t() | nil,
          utilization: float() | nil,
          status: String.t() | nil,
          reset_at: DateTime.t() | nil,
          captured_at: DateTime.t() | nil,
          overage_status: String.t() | nil,
          window_label: String.t()
        }

  defstruct provider: nil,
            utilization: nil,
            status: nil,
            reset_at: nil,
            captured_at: nil,
            overage_status: nil,
            window_label: "primary"

  @doc """
  Project a persisted quota row onto the provider-neutral gate shape.

  Accepts `AnthropicQuota` / `CodexQuota` / `GoogleQuota` rows, an already
  normalized `#{inspect(__MODULE__)}`, or `nil`. Anything else → `nil`
  (fail open).
  """
  @spec normalize(term()) :: t() | nil
  def normalize(nil), do: nil

  def normalize(%__MODULE__{} = snapshot), do: snapshot

  def normalize(%AnthropicQuota{} = q) do
    %__MODULE__{
      provider: q.provider,
      utilization: q.utilization_5h,
      status: q.status_5h,
      reset_at: q.reset_5h_at,
      captured_at: q.captured_at,
      overage_status: q.overage_status,
      window_label: "5h"
    }
  end

  def normalize(%CodexQuota{} = q) do
    %__MODULE__{
      provider: q.provider,
      utilization: fraction(q.session_used_percent),
      status: if(q.limit_reached == true, do: "limit_reached"),
      reset_at: q.session_reset_at,
      captured_at: q.captured_at,
      window_label: "session"
    }
  end

  def normalize(%GoogleQuota{} = q) do
    %__MODULE__{
      provider: q.provider,
      utilization: fraction(q.used_percent),
      # Google's Cloud Code Assist API reports no allowed/rejected verdict — the
      # representative used-percent is the only gating signal.
      status: nil,
      reset_at: q.reset_at,
      captured_at: q.captured_at,
      window_label: "used"
    }
  end

  def normalize(_other), do: nil

  # Codex and Google report 0-100 used-percents; the gate threshold is a 0-1
  # fraction (Anthropic's native unit).
  defp fraction(nil), do: nil
  defp fraction(pct) when is_number(pct), do: pct / 100.0
  defp fraction(_), do: nil
end
