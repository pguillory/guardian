defmodule Guardian.Query.Function.GenerateUUIDTest do
  use Guardian.Query.EvaluationTestCase, async: true
  alias Guardian.Storage.Column

  test "generate_uuid function" do
    [uuid1, uuid2] =
      Guardian.Query.Evaluation.eval(snapshot([%{}, %{}]), "generate_uuid()") |> Column.to_list()

    UUID.string_to_binary!(uuid1)
    UUID.string_to_binary!(uuid2)
    assert uuid1 != uuid2
  end
end
