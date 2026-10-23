defmodule Query.Function.EmailUsername do
  def eval(value) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [username, _domain] -> username
      _ -> nil
    end
  end

  def eval(_) do
    nil
  end
end
