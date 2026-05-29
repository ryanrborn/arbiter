defmodule Arbiter.Mergers.Github.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Mergers.Github` callback on
  failure. Mirrors the shape of `Arbiter.Trackers.Jira.Error` and
  `Arbiter.GitHub.Error` for consistency.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue
    * `:not_found` — 404, PR/repo doesn't exist
    * `:validation_failed` — 400/422, GitHub rejected the body
    * `:conflict` — 409, the PR could not be merged (head moved, base changed)
    * `:not_mergeable` — 405, the PR is not in a mergeable state
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:config_missing` — workspace config is missing owner / repo /
      credentials, or no active workspace is set
  """

  defstruct [:kind, :status, :message, :raw]

  @type kind ::
          :unauthenticated
          | :forbidden
          | :not_found
          | :validation_failed
          | :conflict
          | :not_mergeable
          | :server_error
          | :http
          | :network
          | :config_missing

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
