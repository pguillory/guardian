defmodule Guardian.AST.ParseError do
  @moduledoc """
  Why a source text did not parse: what `Guardian.AST.Parser` and
  `Guardian.AST.Tokenizer` return as `{:error, error}`. Bad input is an expected outcome,
  so this is a plain struct, never raised.
  """

  @enforce_keys [:reason, :row, :col]
  defstruct [:reason, :row, :col]

  @type t :: %__MODULE__{reason: String.t(), row: non_neg_integer(), col: non_neg_integer()}

  def message(%__MODULE__{reason: reason, row: row, col: col}) do
    "Parse error on line #{row + 1} column #{col + 1}: #{reason}"
  end
end
