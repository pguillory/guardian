# Used by "mix format"
defmodule Guardian.Formatter do
  @behaviour Mix.Tasks.Format
  # Mix loads formatter dependencies after evaluating this configuration.
  @compile {:no_warn_undefined, FreedomFormatter}

  defdelegate features(opts), to: FreedomFormatter

  def format(content, opts) do
    # Build tooling only. Newly wrapped literals need a second pass for commas:
    # https://github.com/marcandre/freedom_formatter/issues/9
    content
    |> FreedomFormatter.format(opts)
    |> FreedomFormatter.format(opts)
  end
end

[
  plugins: [Guardian.Formatter],
  trailing_comma: true,
  locals_without_parens: [throw: 1],
  inputs: ["*.{heex,ex,exs}", "{config,lib,libtest,test}/**/*.{heex,ex,exs}"],
]
