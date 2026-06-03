defmodule Arbiter.Trackers.Shortcut.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Trackers.Shortcut` function on
  failure. Mirrors `Arbiter.Trackers.Jira.Error` for consistency.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue
    * `:not_found` — 404, story/workflow doesn't exist
    * `:validation_failed` — 400/422, Shortcut rejected the body
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:transition_not_found` — the requested bead status had no mapping to a
      Shortcut workflow state available in the configured workflow(s)
    * `:config_missing` — workspace config is missing credentials, or no active
      workspace is set
    * `:not_implemented` — a callback that's part of the `Tracker` behaviour
      but hasn't been wired up for this adapter yet (currently `create/1`).
  """

  defstruct [:kind, :status, :message, :raw]

  @type kind ::
          :unauthenticated
          | :forbidden
          | :not_found
          | :validation_failed
          | :server_error
          | :http
          | :network
          | :transition_not_found
          | :config_missing
          | :not_implemented

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
