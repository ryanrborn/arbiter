defmodule ArbiterCliTest do
  use ExUnit.Case, async: true

  test "module is defined" do
    Code.ensure_loaded!(ArbiterCli)
    assert is_atom(ArbiterCli)
  end
end
