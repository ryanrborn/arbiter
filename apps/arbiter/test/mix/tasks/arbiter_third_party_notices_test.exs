defmodule Mix.Tasks.Arbiter.ThirdPartyNoticesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Arbiter.ThirdPartyNotices

  @repo_root Path.expand("../../../../..", __DIR__)

  test "generate/0 matches the committed THIRD_PARTY_NOTICES.md" do
    committed = File.read!(Path.join(@repo_root, "THIRD_PARTY_NOTICES.md"))

    assert ThirdPartyNotices.generate() == committed
  end

  test "generate/0 lists every package from mix.lock with a name, version and SPDX license" do
    text = ThirdPartyNotices.generate()

    assert text =~ "| req | 0.7.3 | Apache-2.0 |"
    assert text =~ "| heroicons |"
    assert text =~ "MIT"
  end

  test "licenses_for/2 reads the licenses field out of hex_metadata.config" do
    assert ThirdPartyNotices.licenses_for("req", @repo_root) == ["Apache-2.0"]
  end

  test "licenses_for/2 raises, naming the package, when no local metadata exists" do
    tmp = System.tmp_dir!() |> Path.join("tpn_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([tmp, "deps", "mystery_dep"]))

    on_exit(fn -> File.rm_rf!(tmp) end)

    assert_raise Mix.Error, ~r/mystery_dep/, fn ->
      ThirdPartyNotices.licenses_for("mystery_dep", tmp)
    end
  end
end
