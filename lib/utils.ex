defmodule Utils do
  def tab2stream(tab, opts \\ []) do
    [delete_after: delete_after] = SuperList.take_opts(opts, delete_after: false)

    start_fun = fn ->
      :ets.first(tab)
    end

    next_fun = fn
      :"$end_of_table" ->
        {:halt, :"$end_of_table"}

      key ->
        {:ets.lookup(tab, key), :ets.next(tab, key)}
    end

    after_fun = fn _ ->
      if delete_after do
        true = :ets.delete(tab)
      end
    end

    Stream.resource(start_fun, next_fun, after_fun)
  end

  def hostname do
    case Application.fetch_env(:guardian, :hostname) do
      :error ->
        {:ok, hostname_list} = :inet.gethostname()
        hostname = to_string(hostname_list)
        :ok = Application.put_env(:guardian, :hostname, hostname)
        hostname

      {:ok, hostname} ->
        hostname
    end
  end

  def simultaneously(funcs, timeout \\ 5000) do
    tasks = Enum.map(funcs, &Task.async/1)
    Task.await_many(tasks, timeout)
  end
end
