defmodule Guardian.Rules.Step.Unset do
  @moduledoc "A parsed UNSET's inputs and diagnostic location."
  defstruct [:table, :file, :line, :index, :field, :source, :where_expr, kind: :unset, reads: []]
end
