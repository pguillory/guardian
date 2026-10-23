{:ok, db} = Hyperscan.compile("quick", 0, Hyperscan.mode("HS_MODE_BLOCK"))
{:ok, scratch} = Hyperscan.alloc_scratch(db)
:ok = Hyperscan.realloc_scratch(db, scratch)
event = %{"timestamp" => Timestamp.now()}
Process.put(:scratch, scratch)
{:ok, serialized_db} = Hyperscan.serialize_database(db)
:ets.new(:hyperscan_databases, [:named_table])
:ets.insert(:hyperscan_databases, {123, db})

Benchee.run(%{
  "alloc_scratch" => fn ->
    {:ok, _scratch} = Hyperscan.alloc_scratch(db)
  end,
  "realloc_scratch" => fn ->
    :ok = Hyperscan.realloc_scratch(db, scratch)
  end,
  "scratch_size" => fn ->
    {:ok, _scratch_size} = Hyperscan.scratch_size(scratch)
  end,
  "deserialize_database" => fn ->
    {:ok, _db} = Hyperscan.deserialize_database(serialized_db)
  end,
  ":ets.lookup" => fn ->
    :ets.lookup(:hyperscan_databases, 123)
  end,
  # "match" => fn ->
  #   Hyperscan.match(db, "the quick brown fox", scratch)
  # end,
  # "identifier" => fn ->
  #   Map.get(event, "timestamp")
  # end,
})
