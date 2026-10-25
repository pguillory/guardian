defmodule Guardian.Query.Function.CosineSimilarityTest do
  use Guardian.Query.EvaluationTestCase, async: true

  test "cosine_similarity function" do
    a = [1, 1, 1, 1, 1, 0, 0]
    b = [0, 0, 1, 1, 0, 1, 1]
    assert eval("cosine_similarity(a, b)", a: a, b: b) === 0.4472135954999579

    assert eval("cosine_similarity([1], [1])") === 1.0
    assert eval("cosine_similarity([1, 1], [1])") === nil
    assert eval("cosine_similarity([1], [1, 1])") === nil
    assert eval("cosine_similarity(a, b)", a: [1.0e150], b: [1.0e150]) === 1.0
  end

  test "cosine_similarity gives null when there is no similarity to compute" do
    for {a, b} <- [
          {[], []},
          {[0, 0], [1, 1]},
          {[1, nil], [1, 1]},
          {[1, "a"], [1, 1]},
          {[1, true], [1, 1]},
          {[1, [2]], [1, 1]},
          {[1.0e200], [1.0e200]},
          {[1.0e-200], [1.0e-200]},
          {[1], 1},
          {nil, [1]},
        ] do
      assert eval("cosine_similarity(a, b)", a: a, b: b) === nil, inspect({a, b})
    end
  end
end
