defmodule Query.Function.GenerateUUIDTest do
  use Query.EvaluationTestCase, async: false
  alias Storage.Column

  test "generate_uuid function" do
    [uuid1, uuid2] =
      Query.Evaluation.eval(snapshot([%{}, %{}]), "generate_uuid()") |> Column.to_list()

    UUID.string_to_binary!(uuid1)
    UUID.string_to_binary!(uuid2)
    assert uuid1 != uuid2
  end
end
