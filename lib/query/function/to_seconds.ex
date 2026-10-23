defmodule Query.Function.ToSeconds do
  def eval(timestamp) when is_binary(timestamp) do
    Timestamp.to_seconds(timestamp)
  catch
    _kind, _reason ->
      nil
  end

  def eval(_) do
    nil
  end
end
