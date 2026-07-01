defmodule Arbiter.Trackers.Gitlab.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Trackers.Gitlab` callback on
  failure. Mirrors the shape of `Arbiter.Trackers.GitHub.Error` and
  `Arbiter.Mergers.Gitlab.Error` for consistency.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue or rate-limit hit
    * `:not_found` — 404, issue/project doesn't exist
    * `:validation_failed` — 400/422, GitLab rejected the body (or a response
      came back shaped wrong)
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:transition_not_found` — the requested task status had no mapping to a
      GitLab state/label in the workspace's `status_map`
    * `:config_missing` — workspace config is missing host / project_id /
      credentials, or no active workspace is set
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

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
