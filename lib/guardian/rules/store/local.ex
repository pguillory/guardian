defmodule Guardian.Rules.Store.Local do
  @moduledoc """
  Rule files in a local folder: `<dir>/<table>/<name>.gsql`, and the write lock at
  `<dir>/_write.lock`. ETags are content hashes. Writes go to a temporary file that is
  renamed into place; this node's writes to the folder are serialized, so conditional
  puts are atomic here. Each node has its own folder, so `Guardian.Rules.Server` refuses
  writes while other nodes are connected.
  """

  @behaviour Guardian.Rules.Store

  @enforce_keys [:dir]
  defstruct [:dir]

  @doc "The store for `dir`, creating the folder. `{:error, reason}` if it cannot."
  def new(dir) do
    case File.mkdir_p(dir) do
      :ok -> {:ok, {__MODULE__, %__MODULE__{dir: dir}}}
      {:error, posix} -> {:error, {:misconfigured, "#{dir}: #{:file.format_error(posix)}"}}
    end
  end

  @impl true
  def describe(%__MODULE__{dir: dir}) do
    "local folder #{dir}"
  end

  @impl true
  def list(%__MODULE__{dir: dir}) do
    if File.dir?(dir) do
      # Only regular files: a folder that happens to be named like a rule file holds
      # no rules. A file that can't be read fails the whole listing (the store is
      # misconfigured), which a running node survives by keeping its rules.
      rule_files =
        [dir, "*", "*.gsql"]
        |> Path.join()
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?/1)

      lock = Path.join(dir, "_write.lock")
      paths = if File.exists?(lock), do: [lock | rule_files], else: rule_files

      objects =
        Enum.reduce_while(paths, [], fn path, objects ->
          case File.read(path) do
            {:ok, body} ->
              key = Path.relative_to(path, dir)
              {:cont, [%{key: key, etag: etag(body), size: byte_size(body)} | objects]}

            {:error, :enoent} ->
              {:cont, objects}

            {:error, posix} ->
              {:halt, {:error, {:failed, "#{Path.relative_to(path, dir)}: #{posix}"}}}
          end
        end)

      case objects do
        {:error, reason} -> {:error, reason}
        objects -> {:ok, Enum.sort_by(objects, & &1.key)}
      end
    else
      {:error, {:misconfigured, "#{dir} is not a folder"}}
    end
  end

  @impl true
  def get(%__MODULE__{} = config, key, etag) do
    path = path(config, key)

    with {:ok, body} <- read(path),
         {:ok, %File.Stat{mtime: mtime}} <- stat(path) do
      cond do
        etag != nil and etag(body) != etag ->
          {:error, :precondition_failed}

        true ->
          age_ms = (System.os_time(:second) - mtime) * 1000
          {:ok, body, %{etag: etag(body), age_ms: age_ms}}
      end
    end
  end

  @impl true
  def put(%__MODULE__{} = config, key, body, condition) do
    path = path(config, key)

    serialized(config, fn ->
      current =
        case File.read(path) do
          {:ok, current} -> etag(current)
          {:error, _} -> nil
        end

      case {condition, current} do
        {:absent, current} when current != nil -> {:error, :precondition_failed}
        {{:etag, etag}, current} when current != etag -> {:error, :precondition_failed}
        _ -> write(path, body)
      end
    end)
  end

  @impl true
  def delete(%__MODULE__{} = config, key) do
    serialized(config, fn ->
      case File.rm(path(config, key)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, posix} -> {:error, {:failed, Atom.to_string(posix)}}
      end
    end)
  end

  defp write(path, body) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      {:ok, etag(body)}
    else
      {:error, posix} -> {:error, {:failed, Atom.to_string(posix)}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :not_found}
      {:error, posix} -> {:error, {:failed, Atom.to_string(posix)}}
    end
  end

  defp stat(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :not_found}
      {:error, posix} -> {:error, {:failed, Atom.to_string(posix)}}
    end
  end

  defp serialized(%__MODULE__{dir: dir}, fun) do
    :global.trans({__MODULE__, dir}, fun, [node()])
  end

  # Keys come from Guardian.Rules.RuleSet.key/2 (validated table and file names) or are the
  # lock; anything else would escape the folder.
  defp path(%__MODULE__{dir: dir}, key) do
    if key == "_write.lock" or match?({:ok, _, _}, Guardian.Rules.RuleSet.parse_key(key)) do
      Path.join(dir, key)
    else
      raise ArgumentError, "invalid rule store key"
    end
  end

  defp etag(body) do
    :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) |> binary_part(0, 32)
  end
end
