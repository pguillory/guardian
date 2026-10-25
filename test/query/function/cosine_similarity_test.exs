defmodule Guardian.Query.Function.CosineSimilarityTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "cosine_similarity function" do
    a = [1, 1, 1, 1, 1, 0, 0]
    b = [0, 0, 1, 1, 0, 1, 1]
    assert eval("cosine_similarity(a, b)", a: a, b: b) === 0.4472135954999579

    assert eval("cosine_similarity([1], [1])") === 1.0
    assert eval("cosine_similarity([1, 1], [1])") === nil
  end
end
