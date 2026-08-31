defmodule DpExchange.Schwab.Supervisor do
  @moduledoc """
  This venue's process tree — internal.

  A limiter and a feed, exactly as every other venue in the family, even though the feed
  behind them is a poll rather than a socket. That sameness is the point: a consumer's
  supervision tree looks identical whichever venue it holds.

  ## The limiter is configured, not declared

  Every other venue in the family takes its limits from `capabilities/0`. This one cannot:
  Schwab's documented ceiling is `0..120` order writes per minute **per account**, set
  **per application at registration**, so there is no venue constant to read. A number
  baked in here would be a claim about somebody else's registration.

  So the limits come from options, and the default is deliberately generous for reads —
  which the venue documents as unthrottled — while a host that places orders should pass
  `:order_limit_per_minute` matching what its own app was registered with. Zero is a legal
  registration value, and a host with it should pass `0` rather than discover the ceiling
  by being refused.
  """

  use Supervisor

  alias DpExchange.Core.DefaultRateLimiter
  alias DpExchange.Schwab.Feed

  # Reads are documented as unthrottled. This is a courtesy ceiling rather than a measured
  # one, and it is not a claim about the venue — it exists so a runaway poll cannot become
  # a self-inflicted incident.
  @default_read_limit 120

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = [
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits(opts)},
      {Feed,
       opts |> Keyword.put(:name, feed_name(opts)) |> Keyword.put(:limiter, limiter_name(opts))}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The limiter this venue meters against."
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts), do: Keyword.get(opts, :limiter, DpExchange.Schwab.RateLimiter)

  @doc "This venue's feed process."
  @spec feed_name(keyword()) :: atom()
  def feed_name(opts), do: Keyword.get(opts, :feed, Feed)

  @doc """
  The limits this tree meters with.

  `:read_limit_per_minute` defaults to #{@default_read_limit}; `:order_limit_per_minute`
  has **no default**, because the venue has no default — see the moduledoc.
  """
  @spec limits(keyword()) :: map()
  def limits(opts) do
    reads = Keyword.get(opts, :read_limit_per_minute, @default_read_limit)
    orders = Keyword.get(opts, :order_limit_per_minute, reads)

    %{
      default: %{limit: reads, per_ms: 60_000, burst: reads},
      schwab: %{limit: reads, per_ms: 60_000, burst: reads},
      schwab_orders: %{limit: max(orders, 1), per_ms: 60_000, burst: max(orders, 1)}
    }
  end

  @doc "Default read ceiling, which is a courtesy rather than a measurement."
  @spec default_read_limit() :: pos_integer()
  def default_read_limit, do: @default_read_limit
end
