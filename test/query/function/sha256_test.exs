defmodule Query.Function.Sha256Test do
  use Query.EvaluationTestCase, async: true

  test "sha256 function" do
    assert eval("sha256('abc')") ===
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
