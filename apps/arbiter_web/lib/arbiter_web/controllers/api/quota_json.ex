defmodule ArbiterWeb.Api.QuotaJSON do
  @moduledoc false

  def show(%{workspace_id: ws_id, claude: claude, quotas: quotas}) do
    %{data: %{workspace_id: ws_id, claude: claude, quotas: quotas}}
  end
end
