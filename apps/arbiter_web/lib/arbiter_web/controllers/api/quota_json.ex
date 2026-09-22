defmodule ArbiterWeb.Api.QuotaJSON do
  @moduledoc false

  def show(%{workspace_id: ws_id, claude: claude, quotas: quotas} = assigns) do
    %{
      data: %{
        # Deprecated since P5 (`docs/provider-account-design.md` §6): the
        # quota rows are keyed by provider account now, and each `quotas`
        # entry carries its own `account`. Kept for one release as the alias
        # for "the workspace this lookup came in through".
        workspace_id: ws_id,
        workspace: Map.get(assigns, :workspace),
        requested_workspace: Map.get(assigns, :requested_workspace),
        account: Map.get(assigns, :account),
        workspaces: Map.get(assigns, :workspaces) || [],
        claude: claude,
        quotas: quotas,
        codex: Map.get(assigns, :codex),
        codex_message: Map.get(assigns, :codex_message),
        codex_credentials_expired: Map.get(assigns, :codex_credentials_expired, false),
        gemini: Map.get(assigns, :gemini),
        antigravity: Map.get(assigns, :antigravity),
        gemini_credentials_expired: Map.get(assigns, :gemini_credentials_expired, false)
      }
    }
  end
end
