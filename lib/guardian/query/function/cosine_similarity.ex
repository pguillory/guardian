defmodule Guardian.Query.Function.CosineSimilarity do
  # A non-number element, empty lists or a zero vector (division by zero, including
  # squares that underflow to 0.0) and float overflow all raise badarith: null.
  def eval(vector1, vector2)
      when is_list(vector1) and is_list(vector2) and length(vector1) == length(vector2) do
    ab = SuperList.reduce(vector1, vector2, 0, &(&1 * &2 + &3))
    aa = SuperList.reduce(vector1, 0, &(&1 * &1 + &2))
    bb = SuperList.reduce(vector2, 0, &(&1 * &1 + &2))
    ab / (:math.sqrt(aa) * :math.sqrt(bb))
  catch
    :error, :badarith -> nil
  end

  def eval(_, _) do
    nil
  end
end
