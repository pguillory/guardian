defmodule Guardian.Query.Function.TestRaise do
  @moduledoc false
  # Registered only in the test build (Guardian.Query.Function): raises ArithmeticError on any
  # value but null, so tests can make a worker's evaluation fail.
  def eval(nil) do
    nil
  end

  def eval(value) do
    raise(ArithmeticError, message: "test_raise(#{inspect(value)})")
  end
end
