defmodule DpExchange.Schwab.Feed do
  @moduledoc """
  This venue's feed — **a REST poll**, and nothing outside this module needs to know that.

  ## Why a venue with no socket still has a feed

  Neither of Schwab's Trader API specifications describes a streaming surface. Behind a
  feed that does not matter: the same `Core.Types.Quote` reaches the same subscriber as
  from a WebSocket venue, no consumer branches on transport, and `coverage/1` reports what
  is actually arriving rather than what was subscribed (D12, §6.1.8).

  Schwab does publish a separate **Thinkorswim** API product, which is where a streaming
  quote surface would live if it exists. Nothing here has been checked against it, and it
  is out of scope for this package — recorded so a reader looking for a Schwab socket
  knows where to look next rather than concluding there is none.

  ## The market closes, and silence is usually correct

  This is the first venue in the family where delivering nothing is the normal overnight
  state rather than a fault. A consumer that alarms on silence would alarm every night and
  all weekend, which makes a real outage indistinguishable from a Saturday — so
  `market_status/1` exists, is answered from `/markets`, and is the thing to check before
  concluding a quiet feed is broken.

  The feed does not stop itself when the market closes. That is deliberate: pausing would
  make "closed" and "crashed" look the same from outside, and pre-market and post-market
  sessions are real trading windows this package must not decide are uninteresting.

  ## One request per symbol, and the cost is real

  `/quotes` accepts several symbols at once, but the throttle that matters here applies to
  *order writes*, not reads — reads are documented as unthrottled. Even so, each poll is a
  signed request against a token with a 30-minute life, so `Core.PollingFeed` spreads
  symbols across the interval rather than sweeping them in a burst.
  """

  alias DpExchange.Core.PollingFeed
  alias DpExchange.Schwab.Rest

  # Equities move fast intraday, but a REST snapshot every 30 seconds is what the
  # collection layer consumes; faster buys nothing a snapshot can express.
  @interval_ms 30_000

  @doc "Start the poller. `:credentials` are the host's, and are passed to every fetch."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    credentials = Keyword.get(opts, :credentials, %{})
    subscriber = Keyword.get(opts, :subscriber, self())

    request_opts =
      Keyword.take(opts, [
        :limiter,
        :plug,
        :req_adapter,
        :market_data_url,
        :trader_url,
        :retry_attempts
      ])

    PollingFeed.start_link(
      name: Keyword.get(opts, :name),
      label: "schwab",
      symbols: Keyword.get(opts, :symbols, []),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      start_delay_ms: Keyword.get(opts, :start_delay_ms),
      sink: fn quote_struct -> send(subscriber, {:dp_exchange, :schwab, quote_struct}) end,
      on_refusal: fn symbol, reason ->
        send(subscriber, {:dp_exchange, :schwab, {:refused, symbol, reason}})
      end,
      fetch: fn symbol -> Rest.get_price(symbol, credentials, request_opts) end
    )
  end

  @doc "Default poll interval in milliseconds."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc "Replace the polled set."
  @spec update_symbols(pid() | atom(), [String.t()]) :: :ok
  def update_symbols(feed, symbols), do: PollingFeed.update_symbols(feed, symbols)

  @doc """
  What is actually arriving, per symbol.

  Observed, never intended: a symbol asked for and never answered is absent rather than
  reported as covered, because reporting it would assert a delivery that never happened.
  On this venue that distinction does double duty — overnight, nothing is arriving and
  nothing is wrong.
  """
  @spec coverage(pid() | atom()) :: %{String.t() => :internal_poll}
  def coverage(feed), do: PollingFeed.coverage(feed)

  @doc "Whether the poller is delivering, and what it last failed on."
  @spec status(pid() | atom()) :: map()
  def status(feed), do: PollingFeed.status(feed)

  @doc "Child spec, so a consumer supervises this the same way it supervises any venue."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end
end
