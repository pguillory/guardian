defmodule Query.Function.Now do
  def eval do
    Timestamp.now()
  end
end
