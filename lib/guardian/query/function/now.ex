defmodule Guardian.Query.Function.Now do
  def eval do
    Guardian.Timestamp.now()
  end
end
