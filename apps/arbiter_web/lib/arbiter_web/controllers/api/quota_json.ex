defmodule ArbiterWeb.Api.QuotaJSON do
  @moduledoc false

  def show(%{workspace_id: ws_id, claude: claude} = assigns) do
    %{
      data: %{
        workspace_id: ws_id,
        claude: claude,
        gemini: Map.get(assigns, :gemini),
        antigravity: Map.get(assigns, :antigravity)
      }
    }
  end
end
