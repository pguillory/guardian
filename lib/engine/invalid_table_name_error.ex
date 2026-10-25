defmodule Guardian.Engine.InvalidTableNameError do
  @moduledoc """
  Raised when an event is ingested into a table whose name SQL cannot address.
  """

  defexception [:table]

  @impl true
  def message(%{table: table}) do
    "invalid table name #{inspect(table)}: table names must start with a lowercase " <>
      "letter or underscore, contain only lowercase letters, digits, and underscores, " <>
      "be at most #{Guardian.Engine.max_table_name_bytes()} characters, and not be a reserved SQL word"
  end
end
