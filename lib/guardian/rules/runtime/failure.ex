defmodule Guardian.Rules.Runtime.Failure do
  @moduledoc "A rule statement raised. Carries only its location and the failure's kind."
  defexception [:file, :line, :kind]

  @impl true
  def message(%__MODULE__{} = e) do
    "rule #{e.file} line #{e.line} failed (#{e.kind}); the event was not stored"
  end
end
