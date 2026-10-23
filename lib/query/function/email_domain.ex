defmodule Query.Function.EmailDomain do
  def eval(value) when is_binary(value) do
    case String.split(value, "@", parts: 2) do
      [_username, domain] -> domain
      _ -> nil
    end
  end

  def eval(_) do
    nil
  end
end
