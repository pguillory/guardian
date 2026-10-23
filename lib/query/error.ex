defmodule Query.Error do
  @moduledoc """
  A query failure meant for the caller, such as a resource limit or a regular
  expression over its backtracking limit. The message says what went wrong and, where
  possible, what to change. The JSON API answers it with 400 and the message; the MCP
  query tool returns the message as a tool error.
  """

  defexception [:message]
end
