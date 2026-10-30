defmodule Guardian.Test.RaisingValue do
  @moduledoc false
  defstruct [:marker]
end

# Flattening treats a struct value as a map and enumerates it, so an event holding one
# raises inside Engine's validation with a fun frame (carrying the marker) on the stack.
defimpl Enumerable, for: Guardian.Test.RaisingValue do
  def reduce(%{marker: marker}, _acc, _fun) do
    frame = {fn -> marker end, [marker], []}
    :erlang.raise(:error, %RuntimeError{message: marker}, [frame])
  end

  def count(_key) do
    {:error, __MODULE__}
  end

  def member?(_key, _value) do
    {:error, __MODULE__}
  end

  def slice(_key) do
    {:error, __MODULE__}
  end
end
