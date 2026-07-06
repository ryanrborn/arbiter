defmodule ArbiterWeb.Api.QuotaJSON do
  @moduledoc false

  def show(%{workspace_id: ws_id, claude: claude} = assigns) do
    %{
      data: %{
        workspace_id: ws_id,
        claude: claude,
        codex: Map.get(assigns, :codex),
        codex_message: Map.get(assigns, :codex_message)
      }
    }
  end
end
