defmodule Guardian.Counters.Context do
  @moduledoc "Private per-event counter deadlines, shared budget and routing snapshot."
  alias Guardian.Counters.Clock
  @enforce_keys [:batch, :deadline, :timeout_us, :cooldown_table, :members, :store]
  defstruct [:batch, :deadline, :timeout_us, :cooldown_table, :members, :store]

  # Internal test seam, not an operator setting: `config :guardian, __MODULE__,
  # event_ms: _, operation_ms: _` replaces the default and the remote endpoint's bound.
  # Only tests set it, through Guardian.Test.Counters.Budget; production uses these
  # defaults. `new/2`'s budget options replace the default for one event; only tests
  # pass them.
  @event_ms 100
  @operation_ms 50

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
    deadline = Clock.deadline(Keyword.get_lazy(opts, :event_timeout_ms, &event_ms/0))
    timeout_us = Clock.from_ms(Keyword.get_lazy(opts, :timeout_ms, &operation_ms/0))
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

  @doc false
  @spec operation_ms() :: pos_integer()
  def operation_ms do
    budget(:operation_ms, @operation_ms)
  end

  defp event_ms do
    budget(:event_ms, @event_ms)
  end

  # Anything but a positive integer keeps the default, so a bad value cannot open
  # the remote endpoint's bound.
  defp budget(key, default) do
    case Application.get_env(:guardian, __MODULE__, []) |> Keyword.get(key) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> default
    end
  end
end
