defmodule Guardian.Counters.Context do
  @moduledoc "Private per-event counter deadlines, shared budget and routing snapshot."
  @enforce_keys [:batch, :deadline, :timeout_us, :cooldown_table, :members, :store]
  defstruct [:batch, :deadline, :timeout_us, :cooldown_table, :members, :store]

  @event_us 100_000
  @operation_us 50_000

  @type batch :: :atomics.atomics_ref()
  # The libtest adapter additionally interprets backend/server tuples in test builds.
  @type store :: atom() | pid() | reference()
  @type option ::
          {:event_timeout_ms, integer()}
          | {:timeout_ms, integer()}
          | {:cooldown_table, atom() | :ets.tid()}
          | {:members, [node()]}
          | {:store, store()}
  @type t :: %__MODULE__{
          batch: batch(),
          deadline: integer(),
          timeout_us: integer(),
          cooldown_table: atom() | :ets.tid(),
          members: [node()],
          store: store(),
        }

  @spec new(batch(), [option()]) :: t()
  def new(batch, opts \\ []) do
    # Start the event deadline before snapshotting membership.
    deadline =
      System.monotonic_time(:microsecond) +
        min(@event_us, Keyword.get(opts, :event_timeout_ms, 100) * 1_000)

    timeout_us = min(@operation_us, Keyword.get(opts, :timeout_ms, 50) * 1_000)
    cooldown_table = Keyword.get(opts, :cooldown_table, Guardian.Counters.Budget)
    members = Keyword.get_lazy(opts, :members, fn -> [node() | Node.list()] end)

    %__MODULE__{
      batch: batch,
      deadline: deadline,
      timeout_us: timeout_us,
      cooldown_table: cooldown_table,
      members: members,
      store: Keyword.get(opts, :store, Guardian.Counters.Store),
    }
  end
end
