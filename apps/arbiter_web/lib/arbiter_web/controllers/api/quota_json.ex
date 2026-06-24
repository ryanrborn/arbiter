defmodule ArbiterWeb.Api.QuotaJSON do
  @moduledoc false

  def show(%{workspace_id: ws_id, claude: claude}) do
    %{data: %{workspace_id: ws_id, claude: claude}}
  end
end
