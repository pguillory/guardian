defmodule Guardian.Storage.Column.NIF do
  @on_load :init

  def init do
    priv_dir = :code.priv_dir(:guardian)
    nif_path = Path.join(priv_dir, "column")
    :ok = :erlang.load_nif(nif_path, 0)
  end

  def max_string_size do
    exit(:nif_not_loaded)
  end

  def max_list_length do
    exit(:nif_not_loaded)
  end

  def max_list_depth do
    exit(:nif_not_loaded)
  end

  def new(_capacity) do
    exit(:nif_not_loaded)
  end

  def pad(_column, _count) do
    exit(:nif_not_loaded)
  end

  def append(_column, _value) do
    exit(:nif_not_loaded)
  end

  def valid_value(_value) do
    exit(:nif_not_loaded)
  end

  def pack(_column) do
    exit(:nif_not_loaded)
  end

  def packed_size(_column) do
    exit(:nif_not_loaded)
  end

  def allocated_size(_column) do
    exit(:nif_not_loaded)
  end

  def live_columns do
    exit(:nif_not_loaded)
  end

  def get_value(_column, _offset) do
    exit(:nif_not_loaded)
  end

  def from_list(_column) do
    exit(:nif_not_loaded)
  end

  def to_list(_column) do
    exit(:nif_not_loaded)
  end

  def count(_column) do
    exit(:nif_not_loaded)
  end

  def null_count(_column) do
    exit(:nif_not_loaded)
  end

  def false_count(_column) do
    exit(:nif_not_loaded)
  end

  def true_count(_column) do
    exit(:nif_not_loaded)
  end

  def int_count(_column) do
    exit(:nif_not_loaded)
  end

  def float_count(_column) do
    exit(:nif_not_loaded)
  end

  def string_count(_column) do
    exit(:nif_not_loaded)
  end

  def metadata(_column) do
    exit(:nif_not_loaded)
  end

  def filter(_column1, _column2) do
    exit(:nif_not_loaded)
  end

  def add(_column1, _column2) do
    exit(:nif_not_loaded)
  end

  def subtract(_column1, _column2) do
    exit(:nif_not_loaded)
  end

  def multiply(_column1, _column2) do
    exit(:nif_not_loaded)
  end

  def divide(_column1, _column2) do
    exit(:nif_not_loaded)
  end

  def and_oper(_column1, _column2) do
    exit(:nif_not_loaded)
  end

  def or_oper(_column1, _column2) do
    exit(:nif_not_loaded)
  end

  def not_oper(_column1) do
    exit(:nif_not_loaded)
  end

  def min_max_number(_column) do
    exit(:nif_not_loaded)
  end

  def number_to_false(_column) do
    exit(:nif_not_loaded)
  end

  def number_to_true(_column) do
    exit(:nif_not_loaded)
  end

  def to_boolean(_column) do
    exit(:nif_not_loaded)
  end

  def to_string(_column) do
    exit(:nif_not_loaded)
  end
end
