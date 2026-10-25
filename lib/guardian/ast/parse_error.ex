defmodule Guardian.AST.ParseError do
  @enforce_keys [:reason, :row, :col]
  defstruct __exception__: true, reason: nil, row: nil, col: nil

  def exception(reason: reason, row: row, col: col) do
    %__MODULE__{reason: reason, row: row, col: col}
  end

  def message(%__MODULE__{reason: reason, row: row, col: col}) do
    "Parse error on line #{row + 1} column #{col + 1}: #{reason}"
  end
end
