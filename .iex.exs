# defmodule Helper do
#   defmacro maybe_import({:__aliases__, _, [module]}) do
#     module = Module.concat(Elixir, module)

#     if Code.ensure_loaded?(module) and not function_exported?(module, :__info__, 1) do
#       quote do
#         import unquote(module)
#       end
#     end
#   end
# end

# require Helper

# Helper.maybe_import(Console)
# Helper.maybe_import(Timeit)
