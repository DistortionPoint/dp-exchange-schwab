defmodule DpExchange.Schwab.Ledger do
  @moduledoc """
  What a tree's feed has been asked to do, held outside the feed so a feed crash does not lose it
  — internal.

  ## The defect this closes

  `DpExchange.Schwab.Feed` restarts from the supervisor's static start options, which carry
  none of what consumers did afterwards: every `subscribe/2`, every notice registration and the
  credential pushed by `update_credentials/2`. A crash therefore left each consumer subscribed
  to a feed that remembered none of them, with no notice that anything had happened.

  ## What it holds

  One snapshot, replaced whole on every change `Feed` ACCEPTS (a refused call writes nothing):
  the wanted symbols, the data subscribers, the notice subscribers and the credential in force.
  The credential is kept in its redacting `DpExchange.Schwab.Credentials` struct, so the
  ledger's state prints without a secret. A restarted feed reads it back in `handle_continue/2`,
  re-monitors the subscribers, restores the wanted set and credential, redials, and tells its
  subscribers with a `:link_down` notice.

  The ledger is a sibling started before the feed, named per tree (derived from the tree's
  `name:` like the other processes, see `DpExchange.Schwab.Supervisor.ledger_name/1`). It is
  only an `Agent`: it holds a value and does no work that can crash. A feed started alone has no
  ledger and keeps nothing across a restart.
  """

  @typedoc "The durable intent of one feed."
  @type snapshot :: %{
          wanted: [String.t()],
          subscribers: [pid() | atom()],
          notice_subscribers: [pid() | atom()],
          credentials: DpExchange.Schwab.Credentials.t()
        }

  @doc "Starts an empty ledger registered as `opts[:name]`."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    Agent.start_link(fn -> nil end, name: Keyword.fetch!(opts, :name))
  end

  @doc "Child spec, so the tree supervises this like any other child."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Replaces the snapshot held under `name`. Asynchronous, and silent when nothing is running
  under `name`: a feed's reply never waits on its ledger.
  """
  @spec put(GenServer.server(), snapshot()) :: :ok
  def put(name, snapshot) do
    Agent.cast(name, fn _previous -> snapshot end)
  end

  @doc "The snapshot held under `name`, or `nil` when none was written or nothing is running."
  @spec fetch(GenServer.server()) :: snapshot() | nil
  def fetch(name) do
    Agent.get(name, & &1, 5_000)
  catch
    :exit, _reason -> nil
  end
end
