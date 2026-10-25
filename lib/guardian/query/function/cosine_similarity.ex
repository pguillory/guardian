defmodule Guardian.Query.Function.CosineSimilarity do
  def eval(vector1, vector2) when is_list(vector1) and is_list(vector2) do
    ab = SuperList.reduce(vector1, vector2, 0, &(&1 * &2 + &3))
    aa = SuperList.reduce(vector1, 0, &(&1 * &1 + &2))
    bb = SuperList.reduce(vector2, 0, &(&1 * &1 + &2))
    ab / (:math.sqrt(aa) * :math.sqrt(bb))
  rescue
    _ -> nil
  end

  def eval(_, _) do
    nil
  end
end
