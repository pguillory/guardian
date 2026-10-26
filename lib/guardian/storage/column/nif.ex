defmodule Guardian.Storage.Column.NIF do
  @on_load :init

  def init do
    priv_dir = :code.priv_dir(:guardian)
    nif_path = Path.join(priv_dir, "column")
    :ok = :erlang.load_nif(nif_path, 0)
  end

  # One stub per NIF, in the order of nif_funcs[] in src/column.c; load_nif/2
  # replaces each. test/guardian/storage/column/nif_test.exs checks that they match
  # by name and arity.
  @stubs [
    max_string_size: 0,
    max_list_length: 0,
    max_list_depth: 0,
    new: 1,
    pad: 2,
    append: 2,
    valid_value: 1,
    pack: 1,
    packed_size: 1,
    allocated_size: 1,
    live_columns: 0,
    from_list: 1,
    to_list: 1,
    count: 1,
    null_count: 1,
    false_count: 1,
    true_count: 1,
    int_count: 1,
    float_count: 1,
    string_count: 1,
    metadata: 1,
    filter: 2,
    add: 2,
    subtract: 2,
    multiply: 2,
    divide: 2,
    and_oper: 2,
    or_oper: 2,
    not_oper: 1,
    min_max_number: 1,
    number_to_false: 1,
    number_to_true: 1,
    to_boolean: 1,
    to_string: 1,
  ]

  for {name, arity} <- @stubs do
    def unquote(name)(unquote_splicing(List.duplicate(Macro.var(:_, __MODULE__), arity))) do
      exit(:nif_not_loaded)
    end
  end
end
