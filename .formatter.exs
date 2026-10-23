# Used by "mix format"
[
  plugins: [FreedomFormatter],
  trailing_comma: true,
  locals_without_parens: [throw: 1],
  inputs: ["*.{heex,ex,exs}", "{config,lib,libtest,test}/**/*.{heex,ex,exs}"],
]
