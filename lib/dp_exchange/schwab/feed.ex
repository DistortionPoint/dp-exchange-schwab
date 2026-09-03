defmodule DpExchange.Schwab.Feed do
  @moduledoc """
  This venue's feed — **the Streamer where it can bootstrap, a REST poll where it cannot.**

  ## Why there are two routes and why a consumer sees one

  **Schwab has a WebSocket Streamer, and this package now speaks it.** For most of this
  package's life it did not, and the moduledoc here said so honestly. Before that it said
  something worse — that neither Trader API specification describes a streaming surface,
  which is true, and left the reader to conclude the venue has none, which is false.

  The Streamer carries 15 services — `LEVELONE_*` quotes and top of book, `NYSE_BOOK`,
  `NASDAQ_BOOK` and `OPTIONS_BOOK` for depth, `CHART_*` for candles, and `ACCT_ACTIVITY`
  for order and fill events. It is documented in the prose beside the specifications,
  committed at `docs/reference/schwab/documentation/market-data-production.txt`, and its
  bootstrap is `GET /userPreference`, which returns `streamerInfo.streamerSocketUrl`.

  ## The bootstrap can fail, and the fallback is not a substitution

  `GET /userPreference` is an authenticated call. A credential that cannot make it — no
  token, an expired one, a response without `streamerInfo` — leaves this feed **polling**,
  and `coverage/1` then reports `:internal_poll` for every symbol.

  That is not the family's forbidden substitution, and the difference is worth stating
  precisely: a substitution is a *different value wearing the right label*. Here the label
  changes with the route. A consumer reading `coverage/1` is told which one it got, on every
  symbol, every time it asks. Nothing claims to be a stream that is not one.

  What the fallback does buy is that a Streamer outage degrades to slower quotes rather than
  to silence — and `:degraded` says so.

  ## Only quotes survive the fallback

  The poll fetches `/quotes`. **Depth, candles, orders and fills exist only on the socket**,
  so a feed that fell back delivers none of them and says so through `coverage/1` rather
  than through a subscription that quietly never fires.

  ## The market closes, and silence is usually correct

  This is the first venue in the family where delivering nothing is the normal overnight
  state rather than a fault. A consumer that alarms on silence would alarm every night and
  all weekend, which makes a real outage indistinguishable from a Saturday — so
  `market_status/1` exists, is answered from `/markets`, and is the thing to check before
  concluding a quiet feed is broken.

  The feed does not stop itself when the market closes. That is deliberate: pausing would
  make "closed" and "crashed" look the same from outside, and pre-market and post-market
  sessions are real trading windows this package must not decide are uninteresting.

  ## One request per symbol, and the cost is real — on the poll

  `/quotes` accepts several symbols at once, but the throttle that matters here applies to
  *order writes*, not reads. Even so, each poll is a signed request against a token with a
  30-minute life, so `Core.PollingFeed` spreads symbols across the interval rather than
  sweeping them in a burst. The socket has no such cost: one connection carries every
  symbol.
  """

  use GenServer

  alias DpExchange.Core.{Config, Notice, PollingFeed}
  alias DpExchange.Schwab.{Rest, Socket, StreamerInfo, SymbolFormat}

  # Equities move fast intraday, but a REST snapshot every 30 seconds is what the
  # collection layer consumes; faster buys nothing a snapshot can express. Used only on the
  # fallback route.
  @interval_ms 30_000

  # WebSockex's own send window, which is not configurable. One `update_symbols/2` can send
  # an unsubscribe and a subscribe, so a call can wait out two windows; the third is
  # headroom, because a `GenServer.call` timing out first would surface a slow socket as a
  # caller-side exit rather than as an error the caller can retry.
  @call_timeout 15_000

  # The seams a consumer's test may vary that this process resolves for itself.
  @config_keys [:rate_limit_module, :http_adapter]

  @doc """
  Start the feed. `:credentials` are the host's, and are passed to every fetch.

  **The caller's `Core.Config` overrides are snapshotted here and re-applied inside the
  server.** This process outlives the call that started it and is not in its `$callers`
  chain, so a consumer that swapped the rate limiter for its own async test would otherwise
  find the feed metering against the global one — which is the failure `Core.Config` exists
  to prevent, reappearing at the one boundary a process-scoped lookup cannot cross.

  Re-applying in the server rather than resolving per request is right *here* because a feed
  belongs to one supervision subtree. A shared long-lived server would leak one caller's
  configuration into another's; this one has a single caller by construction.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts = Keyword.put_new(opts, :config_snapshot, Config.snapshot(@config_keys))
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Default poll interval in milliseconds, used on the fallback route."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: @interval_ms

  @doc """
  Add `symbols` to the delivered set.

  **Additive, and against what was *asked for* rather than what has arrived.** Reading the
  current set out of `coverage/1` and re-sending the union looks equivalent and is not:
  coverage reports only what has actually delivered, so a symbol subscribed a moment ago
  and not yet quoted is absent from it — and the next `subscribe/2` would drop it. That is
  the observed-versus-intended distinction this family insists on, pointed the other way,
  and it costs a symbol rather than merely reporting one wrongly.
  """
  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed, symbols, opts \\ []) do
    GenServer.call(feed, {:subscribe, symbols, Keyword.get(opts, :to, self())}, @call_timeout)
  end

  @doc "Remove `symbols` from the delivered set."
  @spec unsubscribe(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def unsubscribe(feed, symbols),
    do: GenServer.call(feed, {:unsubscribe, symbols}, @call_timeout)

  @doc "What has been asked for, which is not what `coverage/1` reports."
  @spec wanted(GenServer.server()) :: [String.t()]
  def wanted(feed), do: GenServer.call(feed, :wanted)

  @doc "Replace the delivered set."
  @spec update_symbols(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def update_symbols(feed, symbols),
    do: GenServer.call(feed, {:update_symbols, symbols}, @call_timeout)

  @doc """
  What is actually arriving, per symbol, and **by which route**.

  Observed, never intended: a symbol asked for and never answered is absent rather than
  reported as covered, because reporting it would assert a delivery that never happened.
  On this venue that distinction does double duty — overnight, nothing is arriving and
  nothing is wrong.

  `:stream` means the Streamer delivered it. `:internal_poll` means this package fetched it.
  A caller that needs depth, candles or fills should check for the first.
  """
  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll}
  def coverage(feed), do: GenServer.call(feed, :coverage)

  @doc "Whether the feed is delivering, on which route, and what it last failed on."
  @spec status(GenServer.server()) :: map()
  def status(feed), do: GenServer.call(feed, :status)

  @doc "Register `opts[:to]` for this package's own notices."
  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed, opts),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  @doc "Child spec, so a consumer supervises this the same way it supervises any venue."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    snapshot = Keyword.get(opts, :config_snapshot, %{})
    apply_config(snapshot)

    subscriber = Keyword.get(opts, :subscriber, self())

    state = %{
      credentials: Keyword.get(opts, :credentials, %{}),
      opts: opts,
      request_opts:
        Keyword.take(opts, [
          :limiter,
          :plug,
          :req_adapter,
          :market_data_url,
          :trader_url,
          :retry_attempts
        ]),
      subscriber: subscriber,
      subscribers: MapSet.new([subscriber]),
      notice_subscribers: MapSet.new(),
      wanted: MapSet.new(Keyword.get(opts, :symbols, [])),
      # An already-established socket. Ordinary use leaves this nil and the feed dials its
      # own; it is set by tests that need the socket-bearing branches without a venue.
      socket: Keyword.get(opts, :socket),
      poller: nil,
      route: nil,
      delivering: %{},
      last_error: nil,
      config_snapshot: snapshot
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, ensure_route(state)}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber}, _from, state) do
    state = %{
      state
      | subscribers: MapSet.put(state.subscribers, subscriber),
        wanted: MapSet.union(state.wanted, MapSet.new(symbols))
    }

    state = ensure_route(state)
    {:reply, apply_symbols(state), state}
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    state = %{
      state
      | wanted: MapSet.difference(state.wanted, MapSet.new(symbols)),
        delivering: Map.drop(state.delivering, symbols)
    }

    {:reply, apply_symbols(state), state}
  end

  def handle_call(:wanted, _from, state), do: {:reply, MapSet.to_list(state.wanted), state}

  def handle_call({:update_symbols, symbols}, _from, state) do
    state = %{
      state
      | wanted: MapSet.new(symbols),
        delivering: Map.take(state.delivering, symbols)
    }

    state = ensure_route(state)
    {:reply, apply_symbols(state), state}
  end

  def handle_call(:coverage, _from, %{route: :poll, poller: poller} = state)
      when is_pid(poller) or is_atom(poller) do
    {:reply, PollingFeed.coverage(poller), state}
  end

  def handle_call(:coverage, _from, state) do
    # Only what arrived. A subscribed symbol that has delivered nothing is absent, and the
    # facade documents absence as `:not_covered`.
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call(:status, _from, %{route: :poll, poller: poller} = state)
      when is_pid(poller) or is_atom(poller) do
    {:reply, poller |> PollingFeed.status() |> Map.put(:route, :internal_poll), state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       route: :stream,
       delivering: map_size(state.delivering),
       wanted: MapSet.size(state.wanted),
       last_error: state.last_error
     }, state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    {:reply, :ok, %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info({:dp_exchange, :schwab, %Notice{} = notice}, state) do
    fan_out(state.notice_subscribers, {:dp_exchange, :schwab, notice})
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :schwab, {:refused, _symbol, _reason}} = message, state) do
    fan_out(state.subscribers, message)
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :schwab, value} = message, state) do
    fan_out(state.subscribers, message)
    {:noreply, record_delivery(state, value)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- routing ------------------------------------------------------------

  defp ensure_route(%{route: route} = state) when route in [:stream, :poll], do: state

  defp ensure_route(state) do
    case start_socket(state) do
      {:ok, socket} ->
        state = %{state | socket: socket, route: :stream}
        apply_symbols(state)
        state

      # `{:refused, …}` and `{:error, …}` are different answers everywhere else in this
      # package and here they are not: the Streamer is unreachable either way, and the
      # remedy — poll, and say so — is the same. The reason travels into the notice, so a
      # consumer can still tell a rejected credential from a network fault.
      other ->
        reason = failure_reason(other)

        # The Streamer could not be bootstrapped. Say so — a consumer reading only
        # `coverage/1` would see `:internal_poll` and have no idea a socket was expected.
        notify(
          state,
          Notice.new(:degraded, :schwab,
            details: %{reason: inspect(reason), fallback: :internal_poll}
          )
        )

        start_poller(%{state | last_error: reason})
    end
  end

  defp failure_reason({:error, reason}), do: reason
  defp failure_reason({:refused, reason}), do: {:refused, reason}
  # No third shape exists — dialyzer proves the two clauses above are total over what
  # `start_socket/1` can return, and a catch-all here would be a branch no input reaches.

  defp start_socket(%{socket: socket} = _state) when is_pid(socket), do: {:ok, socket}

  defp start_socket(state) do
    with {:ok, body} <- Rest.get_user_preference(state.credentials, state.request_opts),
         {:ok, info} <- StreamerInfo.from_user_preference(body),
         {:ok, token} <- access_token(state.credentials) do
      Socket.start_link(
        Keyword.merge(Keyword.take(state.opts, [:url]),
          streamer_info: info,
          access_token: token,
          subscriber: self()
        )
      )
    end
  end

  defp access_token(%{access_token: token}) when is_binary(token), do: {:ok, token}
  defp access_token(_credentials), do: {:error, {:missing_credentials, :schwab}}

  defp start_poller(state) do
    subscriber = self()
    credentials = state.credentials
    request_opts = state.request_opts
    snapshot = state.config_snapshot

    result =
      PollingFeed.start_link(
        label: "schwab",
        symbols: MapSet.to_list(state.wanted),
        interval_ms: Keyword.get(state.opts, :interval_ms, @interval_ms),
        start_delay_ms: Keyword.get(state.opts, :start_delay_ms),
        sink: fn quote_struct -> send(subscriber, {:dp_exchange, :schwab, quote_struct}) end,
        on_refusal: fn symbol, reason ->
          send(subscriber, {:dp_exchange, :schwab, {:refused, symbol, reason}})
        end,
        fetch: fn symbol ->
          # The poller is a third process, and neither this one's dictionary nor the
          # starting caller's reaches it. Re-applying here is what keeps a consumer's
          # async-test seam — its own rate limiter, its own adapter — in force on the
          # fallback route as well as the socket one.
          apply_config(snapshot)
          Rest.get_price(symbol, credentials, request_opts)
        end
      )

    case result do
      {:ok, poller} -> %{state | poller: poller, route: :poll}
      {:error, reason} -> %{state | route: nil, last_error: reason}
    end
  end

  defp apply_symbols(%{route: :poll, poller: poller} = state)
       when is_pid(poller) or is_atom(poller) do
    PollingFeed.update_symbols(poller, MapSet.to_list(state.wanted))
  end

  defp apply_symbols(%{route: :stream, socket: socket} = state) when is_pid(socket) do
    # `SUBS` replaces the service's whole symbol set, which is what a wanted-set update
    # means. `ADD` would accumulate the symbols a caller just removed.
    state.wanted
    |> MapSet.to_list()
    |> Enum.group_by(&service_for/1)
    |> Enum.each(fn {service, symbols} ->
      Socket.subscribe(socket, service, "SUBS", Enum.map(symbols, &native/1))
    end)

    :ok
  end

  defp apply_symbols(_state), do: {:error, :no_route}

  # An option symbol reaches `LEVELONE_OPTIONS`; everything else is an equity. The two
  # services **do not share field numbering**, so routing a symbol to the wrong one decodes
  # every field against the wrong table and produces prices that are the right shape.
  defp service_for(symbol) do
    if SymbolFormat.option?(symbol), do: "LEVELONE_OPTIONS", else: "LEVELONE_EQUITIES"
  end

  defp native(symbol) do
    case SymbolFormat.validate(symbol) do
      {:ok, native} -> native
      # A symbol this package will not send to REST is not sent to the socket either. It
      # reaches the venue unchanged and is refused there rather than silently dropped here.
      {:error, _reason} -> symbol
    end
  end

  defp record_delivery(state, %{symbol: symbol}) when is_binary(symbol) do
    %{state | delivering: Map.put(state.delivering, symbol, :os.system_time(:millisecond))}
  end

  defp record_delivery(state, _value), do: state

  # `Core.Config` resolves through the calling process and its `$callers` chain. A
  # GenServer is in neither, so an override a consumer set for its own async test would be
  # invisible here. Applying the snapshot in whichever process is about to make the request
  # is what carries it across that boundary.
  defp apply_config(snapshot) do
    Enum.each(snapshot, fn {key, value} -> Config.put_override(key, value) end)
  end

  # A dead subscriber stops delivery. The venue must not accumulate events for a process
  # that no longer exists.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn pid -> if Process.alive?(pid), do: send(pid, message) end)
  end

  defp notify(state, notice) do
    fan_out(
      MapSet.union(state.notice_subscribers, state.subscribers),
      {:dp_exchange, :schwab, notice}
    )
  end
end
