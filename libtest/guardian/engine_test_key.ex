defmodule Guardian.EngineTestKey do
  @moduledoc false
  defstruct [:marker]
end

defimpl String.Chars, for: Guardian.EngineTestKey do
  def to_string(%{marker: marker}) do
    frame = {fn -> marker end, [marker], []}
    :erlang.raise(:error, %RuntimeError{message: marker}, [frame])
  end
end
