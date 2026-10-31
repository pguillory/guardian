# :large tests allocate gigabytes; run them by hand with `mix test --only large`.
# :cluster tests start peer VMs and :lifecycle tests stop and start a server; run them
# with `mix test --include cluster --include lifecycle`, which CONTRIBUTING.md asks for
# before every deploy.
# A bare assert_receive waits up to 5 s instead of ExUnit's 100 ms: every one waits on
# another process (often one calling a NIF), which can take longer than 100 ms under
# load. A passing assertion returns as soon as its message arrives, so only a failing
# one waits longer. refute_receive keeps its 100 ms default.
ExUnit.start(exclude: [:large, :cluster, :lifecycle], assert_receive_timeout: 5_000)

# Tests load code on first call, one module at a time through the code server. Under
# async load that took a first MCP client past its 3 s start and a first rule past its
# 1 s row limit, so everything loads here, before any test runs. Mix lists modules
# that are not on disk, and a module that fails to load here just loads, or fails, as usual.
_ =
  Application.started_applications()
  |> Enum.flat_map(fn {app, _description, _version} -> Application.spec(app, :modules) end)
  |> Code.ensure_all_loaded()

# Remove this run's data directory when the VM exits (not in ExUnit.after_suite, which
# runs after every pass of `mix test --repeat-until-failure`). Guardian stops first:
# Storage persists pending segments when it stops and would otherwise write into the
# directory as it is removed.
data_dir = Application.fetch_env!(:guardian, :data_dir)

System.at_exit(fn _status ->
  _ = Application.stop(:guardian)
  File.rm_rf!(data_dir)
end)
