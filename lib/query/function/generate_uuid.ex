defmodule Query.Function.GenerateUUID do
  def eval do
    UUID.uuid4()
  end
end
