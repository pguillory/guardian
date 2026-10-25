defmodule Guardian.Query.Function.Random do
  def eval do
    :rand.uniform()
  end

  @phash2_max 134_217_727.0 = :math.pow(2, 27) - 1

  def eval(seed) do
    :erlang.phash2(seed) / @phash2_max
  end
end
