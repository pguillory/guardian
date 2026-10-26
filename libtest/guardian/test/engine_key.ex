defmodule Guardian.Test.EngineKey do
  @moduledoc false
  defstruct [:marker]
end

defimpl String.Chars, for: Guardian.Test.EngineKey do
  def to_string(%{marker: marker}) do
    frame = {fn -> marker end, [marker], []}
    :erlang.raise(:error, %RuntimeError{message: marker}, [frame])
  end
end
