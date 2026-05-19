defmodule GtElixirCliTest do
  use ExUnit.Case, async: true

  test "module is defined" do
    Code.ensure_loaded!(GtElixirCli)
    assert is_atom(GtElixirCli)
  end
end
