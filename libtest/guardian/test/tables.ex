defmodule Guardian.Test.Tables do
  @moduledoc """
  Table names for tests. Tests that pick different table names cannot interfere, so
  every test that stores events or rules takes its table from here.
  """

  @doc "A table name unique to this VM run, starting with `prefix`."
  def unique_table(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
