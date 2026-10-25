defmodule Guardian.Storage.Mmap do
  # Internal to Storage; see lib/guardian/storage/CLAUDE.md, "Public boundary".
  #
  # Maps whole files read-only into memory as binaries (`src/mmap.c`).
  #
  # The returned binary, and any sub-binary of it, refers to the mapping directly. The
  # file descriptor is closed before `read/1` returns; the mapping is removed when the
  # last binary referring to it is garbage collected. Deleting the file while it is
  # mapped is safe: its data stays readable until then.
  @moduledoc false

  @on_load :init

  def init do
    priv_dir = :code.priv_dir(:guardian)
    :ok = :erlang.load_nif(Path.join(priv_dir, "mmap"), 0)
  end

  @doc "Maps `filename`. Returns `{:ok, binary}` or `{:error, posix_reason}`."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, atom()}
  def read(filename) do
    nif_read(IO.chardata_to_string(filename))
  end

  @doc "Mappings not yet unmapped, across the VM. For tests."
  def live_mappings, do: exit(:nif_not_loaded)

  defp nif_read(_filename), do: exit(:nif_not_loaded)
end
