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

  ## Three kinds are actually subscribed, and three are not — found by defect, not design

  `capabilities/0` once declared `:order_book`, `:orders` and `:fills` streamable on the
  strength of `StreamerDecode` and `Socket.decode/4` being able to turn a `*_BOOK` or
  `CHART_*` frame into a real value. **Decoding is not subscribing**, and this module's own
  routing never asked the venue for any of the three services those kinds need — a consumer
  subscribing to any of them got the declaration and then silence, forever, because nothing
  here ever sent the frame that would start it. That was the defect; this section is its
  correction.

  `:candles` is now wired, because it can be without guessing: `CHART_EQUITY`'s `keys`
  parameter is documented identically to `LEVELONE_EQUITIES`'s — "Equities symbols in upper
  case… e.g.: AAPL,TSLA,IBM" — so `services_for/1` sends the same non-option symbols to both
  services, and `StreamerDecode.to_candle/3` already turns the result into a `Types.Candle`.

  `:order_book` and `:orders`/`:fills` stay **out** of `streamable`, and each for a reason
  that would make wiring it a guess rather than a fix:

  - `NYSE_BOOK` and `NASDAQ_BOOK` are both documented only as "Level Two book for Equities" —
    the vendor names no rule for which of the two a given symbol belongs on. `LEVELONE_EQUITIES`
    field 13 (`exchange_id`, the vendor's "Primary 'listing' Exchange") could in principle
    answer that, but only *after* a quote has already arrived for the symbol, which this
    module does not read for routing today and building that two-hop subscribe-then-route
    flow is new product surface, not a wiring fix. Subscribing every symbol to both books, or
    guessing NYSE for one and NASDAQ for the rest, is exactly the plausible-wrong-answer this
    family exists to refuse.
  - `ACCT_ACTIVITY`'s `message_data` is, per `StreamerFields`' own comment, "a string
    carrying JSON whose shape depends on `message_type`" that "the vendor does not publish in
    this document." There is no `Core.Types.Order` or `Core.Types.Fill` decode to wire,
    because writing one would mean inventing the schema Schwab did not document.

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

  ## The fallback poll going silent is a different failure from the bootstrap failing

  `ensure_route/1` already emits `Notice{kind: :degraded}` once, the instant the Streamer
  bootstrap itself fails — "the socket could not be reached, here is the fallback." That
  says nothing about whether the fallback then keeps working. DpCryptoManagement's issue
  #21 is the reason that gap matters: a poll-based feed on another venue delivered nothing
  for a whole deployment with only a `Logger.warning` to show for it, and nobody was
  grepping in time.

  So the poller started in `start_poller/1` is wired with `Core.PollingFeed`'s `:on_notice`
  (Core 0.1.50): the instant the fallback poll itself crosses into delivering nothing —
  `/quotes` failing every attempt, not the Streamer being unreachable — a second, distinct
  `Notice{kind: :coverage_change, severity: :warning}` fires, and its mirror
  (`severity: :info`, "has resumed delivering") fires once on recovery. Latched the same
  way `PollingFeed` latches its own log line: once per transition, never once per tick.

  **This must never be mistaken for the Streamer's own health, and nothing here is
  structurally ambiguous about it:** `PollingFeed` only ever runs on this venue's `:poll`
  route, so a `:coverage_change` notice can only ever describe the fallback poll — the
  Streamer's own connection health surfaces as `:link_down` / `:link_up` from `Socket` (and
  `:credentials_rejected` when the venue refuses the login itself), different `kind`s
  entirely, on a code path this poller never touches. The
  label passed to `PollingFeed.start_link/1` is `"schwab-fallback-poll"`, not `"schwab"`,
  precisely so the notice is unambiguous on its text alone too — a consumer reading only
  the message pasted into an issue, with no other context, can tell at a glance this is
  about the fallback poll and not the socket.

  ## Only quotes survive the fallback

  The poll fetches `/quotes`. **Candles exist only on the socket, and depth, orders and
  fills are not delivered by this package at all** (see above) — so a feed that fell back
  delivers only quotes and says so through `coverage/1` rather than through a subscription
  that quietly never fires.

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

  ## `acquire`, not `check`, on the fallback poll

  A moduledoc worth carrying from `dp_exchange_robinhood`'s `Feed`, which named this shape
  first (DpCryptoManagement's issue #16), and confirmed live at worse scale on
  `dp_exchange_webull`'s own periodic replay (that package's issue #23). The reasoning
  applies here unchanged: `check/3` answers "is there capacity right now," and a poll that
  finds none simply skips the symbol for that cycle — the exact failure mode Robinhood
  measured as 87 of 87 symbols delivering collapsing to 8 of 87 in a single tick, purely
  from our own limiter, not the venue.

  This module's `request_opts` — shared by the fallback poll's `Rest.get_price/3` calls
  and this module's own Streamer-bootstrap call to `Rest.get_user_preference/2` — defaults
  `:rate_limit_blocking` to `true` for exactly that reason: neither call site has a
  one-off caller waiting synchronously on a tight deadline, so blocking for capacity is
  free and a slower cycle beats a missing price. `Rest.request_opts/1` itself does **not**
  default this — a direct, one-off call through `Rest` may legitimately want fail-fast,
  and this module must not decide that for it.

  ## Credentials rotate, and this process outlives one access token

  The access token this feed was started with is good for 30 minutes; a Streamer socket
  is meant to stay up far longer than that. Before `update_credentials/2` existed, there
  was no way to get a refreshed token to a running feed at all — `Auth.refresh/2` was
  reachable only by a caller reaching past the facade to an internal module, and even
  then had nowhere to hand the result. A rejected reconnect months into a deployment,
  with no path back except tearing the whole supervision subtree down, was the honest
  consequence.

  `update_credentials/2` replaces `state.credentials` — every future bootstrap or poll
  fetch signs with the new value — and, on the `:stream` route, pushes the new
  `:access_token` straight into the live `Socket` via `Socket.update_access_token/2`, so
  the *next* `LOGIN` (an ordinary reconnect, or one `Socket`'s own `LOGIN_DENIED` backoff
  is retrying) presents a token that can actually succeed. It does not force a reconnect;
  a session already logged in keeps running on the token it logged in with.

  The host calls `DpExchange.Schwab.Auth.refresh/2` — through the facade as
  `DpExchange.Schwab.refresh_credentials/2` — persists the result per §6.0, and passes it
  here as `DpExchange.Schwab.update_credentials/2`. Both halves of the round trip now
  cross the facade; neither required reaching past it.

  ## A reconnect used to mean silence until a consumer noticed — now it means one frame

  `Socket.handle_disconnect/2` clears the venue's own subscriptions on every reconnect —
  see `Socket`'s own moduledoc, "Reconnection is not resubscription." Before this fix,
  nothing on this side of the link ever acted on that: `handle_info({:dp_exchange,
  :schwab, %Notice{}}, state)` fanned a `:link_up` notice out to consumers and did
  nothing else, so a routine network blip — not a crash, just an ordinary reconnect —
  left this feed connected, logged in, and asking the venue for nothing, until whoever
  was watching `subscribe_notices/1` noticed `:link_up` on their own and called
  `subscribe/2` again. This is the exact "reconnect with no memory" shape
  `dp_exchange_coinbase`'s and `dp_exchange_gemini`'s `Feed` moduledocs record under the
  same heading — this package had never closed it.

  This module now re-issues `state.wanted` on a periodic, unconditional timer, the same
  shape those two packages use rather than a reactive-only fix keyed off `:link_up`:
  unconditional is what survives a notice this process's own crash-recovery might have
  raced, not only the ordinary case. Re-subscribing a service the socket already carries
  costs one frame the venue ignores; not re-subscribing one it silently dropped costs
  this feed's whole coverage until someone notices.

  ## A crashed socket or poller used to be Feed's crash too — and now it is caught

  `start_socket/1` calls `Socket.start_link/1`, and `start_poller/1` calls
  `PollingFeed.start_link/1` — both from inside `Feed`'s own callback (`ensure_route/1`),
  which links either process to `Feed` the way `start_link` always does. `Feed` never
  called `Process.flag(:trap_exit, true)`, so either one exiting abnormally sent an
  untrappable `EXIT` signal along its link and crashed `Feed` too — every subscriber, the
  whole `wanted` set, gone, restarted by `DpExchange.Schwab.Supervisor` from the STATIC
  `opts` it was given at tree-start, which never carry a consumer's later `subscribe/2`
  calls or a credential pushed in through `update_credentials/2`.

  `Feed` now traps exits. A crashed socket or poller clears `state.route`, `state.socket`
  and `state.poller` (so `ensure_route/1` reconsiders the route from scratch rather than
  treating a dead pid as still live) and resets `state.delivering`/`state.kinds` — this
  feed has exactly one active route at a time, so a crash costs everything it was
  delivering, not a partial set — reports a `:link_down` `Core.Notice`, and immediately
  calls `ensure_route/1` again: a fresh Streamer bootstrap if the credential still works,
  falling back to the poll the same way a first-ever bootstrap failure already does.

  ## A consumer that never subscribes must not find a socket open — this venue was the one exception

  The family's own rule, from `CLAUDE.md`, is explicit: **"A library does not start
  itself… A consumer who has not asked for a venue must not find a socket open."** Until
  now this module violated it, unconditionally: `init/1` ended with
  `{:ok, state, {:continue, :connect}}`, and `handle_continue(:connect, state)` called
  `ensure_route/1` immediately — before a single `subscribe/2` had ever been received. A
  tree that supervised this package and never subscribed anything still got
  `Rest.get_user_preference/2` (a signed request against the venue) and, on success, a
  live Streamer `LOGIN`. Found 2026-09-07, the same cross-package audit that found four
  of five venues missing `Process.flag(:trap_exit, true)` (see above) — this time the
  finding ran the other way: `dp_exchange_coinbase`, `dp_exchange_gemini`,
  `dp_exchange_webull` and `dp_exchange_robinhood` were all checked and all four already
  deferred dialling to `subscribe/2` or a first tick. Schwab was the only venue that
  dialled at boot.

  **The eager dial was incidental, not load-bearing.** `ensure_route/1` was already
  reachable from `handle_call({:subscribe, symbols, subscriber}, _from, state)` and
  `handle_call({:update_symbols, symbols}, _from, state)`, both of which call it before
  replying — every path a consumer actually uses to ask for data already established the
  route on demand. The `{:continue, :connect}` bought nothing beyond making the dial
  happen earlier, for every consumer, including the ones who supervise this package and
  never subscribe at all — which is exactly the scenario `dp_exchange_core`'s own
  conformance suite needs to exercise for assertion 18, "link safety" (start the tree,
  kill a linked child, assert `Feed` survives). That behavioural check was designed
  first and rejected specifically because starting this package's real, non-fake tree
  was not reliably network-free — this section is the reason why, and removing the
  eager dial is what makes the stronger check safe to write for the whole family. See
  `dp_exchange_core`'s CHANGELOG, "Unreleased", assertion 18.

  Removing `{:continue, :connect}` from `init/1` surfaced a second, independent defect
  it had been masking: `handle_call(:status, _from, state)`'s fallback clause hardcoded
  `route: :stream` in its reply. That was correct in every case anyone could previously
  observe — `state.route` was always already `:stream` or `:poll` by the time any
  `handle_call` could run, because `init/1`'s `{:continue, :connect}` is processed
  before any queued call, so no caller could ever see `state` between "started" and
  "routed". Deferring the dial makes that window real and observable: a consumer calling
  `status/1` before its first `subscribe/2` would have been told `route: :stream` while
  nothing had dialled anything — the family's signature defect, a plausible value with
  the wrong meaning. The fix reports `state.route` itself rather than the literal, which
  still reads `:stream` once a route is established (nothing observable changes there)
  and reads `nil`, honestly, before one ever is.

  **What a consumer sees differently:** nothing about this package's data or behaviour
  changes once `subscribe/2` is called — the route is established at that first call
  exactly as it always was, and the same `Notice{kind: :degraded}` fires at that moment
  if the Streamer cannot bootstrap. What changes is a consumer that never subscribes at
  all: it used to get a silent OAuth call and, on success, an open Streamer session it
  never asked for and no notice about; now it gets neither. `status/1` reports
  `route: nil`, and `coverage/1`/`coverage_by_kind/1` report `%{}` — the same honest
  "nothing has happened" answer this module already gives for a subscribed symbol that
  has not yet delivered, extended to the case where nothing was ever subscribed at all.
  A consumer that supervises this package as part of a larger tree it does not intend to
  use yet — the exact scenario the family's rule exists for — no longer pays for a
  connection, an OAuth call, or a Streamer session it never asked for. A tradeoff this
  is worth naming rather than hiding: if the Streamer is unreachable, the `:degraded`
  notice now fires on first `subscribe/2` rather than at boot. "Later, on first use" is
  how every other venue in this family already behaves, and a consumer that never
  subscribes has no route to be degraded about in the first place.
  """

  use GenServer

  alias DpExchange.Core.{Config, Notice, PollingFeed}
  alias DpExchange.Core.Types.{Candle, Quote, TopOfBook}
  alias DpExchange.Schwab.{Credentials, Rest, Socket, StreamerInfo, SymbolFormat}

  # Equities move fast intraday, but a REST snapshot every 30 seconds is what the
  # collection layer consumes; faster buys nothing a snapshot can express. Used only on the
  # fallback route.
  @interval_ms 30_000

  # WebSockex's own send window, which is not configurable. One `update_symbols/2` can send
  # an unsubscribe and a subscribe, so a call can wait out two windows; the third is
  # headroom, because a `GenServer.call` timing out first would surface a slow socket as a
  # caller-side exit rather than as an error the caller can retry.
  @call_timeout 15_000

  # Re-issues `state.wanted` on the `:stream` route on this cadence, unconditionally — see
  # the moduledoc's "A reconnect used to mean silence" section. Matches the interval
  # `dp_exchange_coinbase` and `dp_exchange_gemini` use for the identical purpose; there is
  # no measurement behind the number for any of the three, and this one has not been tuned
  # against a wide production scope.
  @resubscribe_interval_ms 60_000

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

  @doc """
  What has been asked for, which is not what `coverage/1` reports.

  # NOTE — reads carry `@call_timeout` explicitly, exactly as the writes above do.
  #
  # They used to take `GenServer.call/2`'s implicit five seconds, and that asymmetry is what
  # turned a bounded delay into a dead caller in dp-exchange-core issue #28: `coverage/1` is
  # the call a consumer's health check makes, so any moment this Feed was busy for longer
  # than five seconds turned a health check into an EXIT — killing the consumer's own
  # process when it read from inside its own `handle_call/3`. Asking whether the venue was
  # healthy was what made it unhealthy.
  #
  # The blocking is fixed at its sources rather than papered over here; this is the second
  # line of defence. A read that has to queue behind something should WAIT for it, never
  # die of it.
  Reachable through the facade as `DpExchange.Schwab.wanted/1`.
  """
  @spec wanted(GenServer.server()) :: [String.t()]
  def wanted(feed), do: GenServer.call(feed, :wanted, @call_timeout)

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
  A caller that needs candles should check for the first — the fallback poll cannot carry
  them.
  """
  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll}
  def coverage(feed), do: GenServer.call(feed, :coverage, @call_timeout)

  @doc """
  What is arriving, per symbol, split by **which kind** of data it is.

  `coverage/1` answers "is anything arriving" and collapses every payload into one
  boolean-shaped route. That was measured to be actively misleading on Coinbase
  (DpCryptoManagement's issue #22): an order-book channel delivered over 11,000 frames
  while quotes were dark, and `coverage/1` correctly-and-uselessly reported the symbol as
  `:stream` regardless — because it counts any payload as coverage, a `Types.OrderBook`
  exactly as much as a `Types.Quote`.

  Schwab makes the same blindness sharper, because this venue *also* conflates kind with
  route. `coverage/1` alone cannot tell a caller "no candles because the venue sent none
  for this symbol" from "no candles because this feed silently fell back to a route that
  structurally cannot carry them" — and this venue's own fallback does exactly that: when
  the Streamer cannot be bootstrapped, `Core.PollingFeed` polls `/quotes` and nothing else,
  so candles never arrive on that route **at all**, for any symbol, regardless of what the
  venue would have sent over the socket.

  ## What each route reports

  On `:stream`, kind is read off the **decoded struct's own type** — `Types.Quote` is
  `:quotes`, `Types.TopOfBook` is `:top_of_book`, `Types.Candle` is `:candles` — never off
  the venue's service name (`LEVELONE_EQUITIES`, `CHART_EQUITY`, …), which must never cross
  this facade. A symbol delivering only a quote appears under `:quotes` and nowhere else;
  a symbol delivering only candles appears under `:candles` and nowhere else. `record_kind/3`
  below has no `Types.OrderBook` clause — `services_for/1` never subscribes a book service,
  so nothing this module's own subscriptions produce is ever that type; see the moduledoc's
  "Three kinds are actually subscribed" section for why.

  On `:poll`, this reports `%{quotes: PollingFeed.coverage(poller)}` and nothing more.
  There is no empty `:candles` key invented to look complete — candles cannot arrive on
  this route, so claiming coverage of zero for it would still be a claim about a kind this
  route cannot carry.

  ## The design-doc scenario this does NOT reach

  Core's moduledoc for this callback describes a venue where "a symbol can legitimately be
  `:internal_poll` for one kind while another is `:stream`". **That is not reachable here.**
  `state.route` is chosen once, for the whole feed, in `ensure_route/1` — the very first
  clause matches and short-circuits once `route` is `:stream` or `:poll`, and nothing in
  this module ever revisits that choice for a live feed. A symbol's kinds can differ from
  each other (quotes but not candles, or the reverse), but every kind for every symbol comes
  from the **same** route, because there is only one route for the process's whole life.

  ## The invariant

  `Map.keys(coverage(feed))` equals the union of symbol-keys across every value in this
  map's result, on both routes, and every kind key present is one `capabilities().streamable`
  declares. `Core.AdapterContract`'s assertion group 15 checks this.
  """
  @spec coverage_by_kind(GenServer.server()) :: %{
          DpExchange.Core.Capabilities.data_kind() => %{String.t() => :stream | :internal_poll}
        }
  def coverage_by_kind(feed), do: GenServer.call(feed, :coverage_by_kind, @call_timeout)

  @doc """
  Whether the feed is delivering, on which route, and what it last failed on.

  Reachable through the facade as `DpExchange.Schwab.status/1`.
  """
  @spec status(GenServer.server()) :: map()
  def status(feed), do: GenServer.call(feed, :status, @call_timeout)

  @doc "Register `opts[:to]` for this package's own notices."
  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed, opts),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  @doc """
  Replaces the credentials this feed signs and connects with — see the moduledoc's
  "Credentials rotate" section.

  Every future bootstrap or poll fetch signs with `credentials`. On the `:stream` route
  with a live socket, its `:access_token` also reaches `Socket.update_access_token/2`
  immediately, so the socket's next `LOGIN` can use it. Does not force a reconnect.
  """
  @spec update_credentials(GenServer.server(), map()) :: :ok
  def update_credentials(feed, credentials),
    do: GenServer.call(feed, {:update_credentials, credentials}, @call_timeout)

  @doc "Child spec, so a consumer supervises this the same way it supervises any venue."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  # `Credentials.wrap_opt/1` for the same reason the venue module's own `child_spec/1` does
  # it (dp-exchange-core issue #29): whatever supervises this child stores these args and
  # OTP prints them on any termination. Reached here on the documented path already wrapped
  # — this covers a consumer that supervises the feed directly.
  def child_spec(opts) do
    opts = DpExchange.Schwab.Credentials.wrap_opt(opts)

    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    # `start_socket/1` and `start_poller/1` both run inside `ensure_route/1`, a `Feed`
    # callback — `Socket.start_link/1` and `PollingFeed.start_link/1` are therefore
    # linked children of `Feed`, not supervised siblings. Without this flag, either one
    # exiting abnormally sends an untrappable EXIT signal along that link and takes
    # `Feed` down with it — see the moduledoc's "A crashed socket or poller used to be
    # Feed's crash too" section, and `handle_info({:EXIT, pid, reason}, state)` below,
    # which this flag is what makes reachable at all.
    Process.flag(:trap_exit, true)

    snapshot = Keyword.get(opts, :config_snapshot, %{})
    apply_config(snapshot)

    validate_interval_ms!(Config.opt(opts, :interval_ms, @interval_ms))

    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)

    subscriber = Keyword.get(opts, :subscriber, self())

    state = %{
      # Wrapped immediately, before it reaches `state` — see `Credentials`'s moduledoc.
      # Every downstream use (`Rest.get_user_preference/2`, `Rest.get_price/3`,
      # `access_token/1`, `Socket.start_link/1`'s `access_token:` opt) keeps working
      # unchanged: a struct is a map.
      credentials: opts |> Keyword.get(:credentials, %{}) |> Credentials.wrap(),
      # `:credentials` stripped rather than carried twice — see the moduledoc's "Why
      # `Feed` no longer stores the raw `opts` it was started with". Nothing below reads
      # `:credentials` back out of `state.opts`; only `state.credentials` is ever signed
      # with.
      opts: Keyword.delete(opts, :credentials),
      request_opts:
        opts
        |> Keyword.take([
          :limiter,
          :plug,
          :req_adapter,
          :market_data_url,
          :trader_url,
          :retry_attempts,
          :rate_limit_blocking
        ])
        |> Keyword.put_new(:rate_limit_blocking, true),
      # The in-flight Streamer bootstrap, or `nil`. `%{ref: reference(), waiting: [from]}`.
      #
      # The bootstrap's slow half — a signed `Rest.get_user_preference/2` round trip — runs
      # in a task, and the callers waiting on it are parked here rather than blocking this
      # GenServer. `waiting` is a list because two subscribes can arrive during one
      # bootstrap and both are owed the same answer; it must never mean two bootstraps, or
      # a consumer subscribing twice in quick succession opens two Streamer connections.
      route_bootstrap: nil,
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
      # `symbol => MapSet.t(Core.Capabilities.data_kind())`, populated only from the
      # delivered struct's own type — see `record_kind/2`. Kept apart from `delivering`
      # (`symbol => arrival timestamp`) rather than folded into it, so nothing already
      # reading `delivering`'s shape had to change to add this.
      kinds: %{},
      last_error: nil,
      config_snapshot: snapshot
    }

    # No `{:continue, :connect}` — this process dials nothing until the first
    # `subscribe/2` or `update_symbols/2` call reaches `ensure_route/1` on its own. See
    # the moduledoc's "A consumer that never subscribes must not find a socket open"
    # section for why an eager dial here used to happen anyway, and what depended on it
    # (nothing did).
    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber}, from, state) do
    state = %{
      state
      | subscribers: MapSet.put(state.subscribers, subscriber),
        wanted: MapSet.union(state.wanted, MapSet.new(symbols))
    }

    settle_route(state, from)
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    state = %{
      state
      | wanted: MapSet.difference(state.wanted, MapSet.new(symbols)),
        delivering: Map.drop(state.delivering, symbols),
        kinds: Map.drop(state.kinds, symbols)
    }

    {:reply, apply_symbols(state), state}
  end

  def handle_call(:wanted, _from, state), do: {:reply, MapSet.to_list(state.wanted), state}

  def handle_call({:update_symbols, symbols}, from, state) do
    state = %{
      state
      | wanted: MapSet.new(symbols),
        delivering: Map.take(state.delivering, symbols),
        kinds: Map.take(state.kinds, symbols)
    }

    settle_route(state, from)
  end

  def handle_call(:coverage, _from, %{route: :poll, poller: poller} = state)
      when is_pid(poller) or is_atom(poller) do
    {:reply, poller_read(state, fn -> PollingFeed.coverage(poller) end, %{}), state}
  end

  def handle_call(:coverage, _from, state) do
    # Only what arrived. A subscribed symbol that has delivered nothing is absent, and the
    # facade documents absence as `:not_covered`.
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  # The poll route reaches `/quotes` and nothing else — see `Rest.get_price/3`, the only
  # fetch this route ever calls — so there is exactly one kind to report, sourced the same
  # way `coverage/1` sources it on this route: from `PollingFeed`, not from `state.kinds`.
  # No `:candles` key is invented here; candles cannot arrive on this route at all.
  def handle_call(:coverage_by_kind, _from, %{route: :poll, poller: poller} = state)
      when is_pid(poller) or is_atom(poller) do
    {:reply,
     poller_read(state, fn -> %{quotes: PollingFeed.coverage(poller)} end, %{quotes: %{}}), state}
  end

  def handle_call(:coverage_by_kind, _from, state) do
    by_kind =
      for {symbol, kind_set} <- state.kinds,
          kind <- MapSet.to_list(kind_set),
          reduce: %{} do
        acc -> Map.update(acc, kind, %{symbol => :stream}, &Map.put(&1, symbol, :stream))
      end

    {:reply, by_kind, state}
  end

  def handle_call(:status, _from, %{route: :poll, poller: poller} = state)
      when is_pid(poller) or is_atom(poller) do
    {:reply,
     poller_read(
       state,
       fn -> poller |> PollingFeed.status() |> Map.put(:route, :internal_poll) end,
       unresponsive_status(state)
     ), state}
  end

  def handle_call(:status, _from, state) do
    # `state.route` itself, never a literal `:stream`. This clause is also the answer
    # before the first `subscribe/2`/`update_symbols/2` — see the moduledoc's "A consumer
    # that never subscribes must not find a socket open" section — where `state.route` is
    # `nil` and reporting `:stream` here would be exactly the plausible-wrong-answer this
    # family refuses: a route that was never dialled, claimed as the live one.
    {:reply,
     %{
       route: state.route,
       delivering: map_size(state.delivering),
       wanted: MapSet.size(state.wanted),
       last_error: state.last_error
     }, state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    {:reply, :ok, %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}}
  end

  def handle_call({:update_credentials, credentials}, _from, state) do
    push_access_token(state, Map.get(credentials, :access_token))
    {:reply, :ok, %{state | credentials: Credentials.wrap(credentials)}}
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

  # Unconditional: sent whether or not a reconnect actually happened, because a socket
  # this process never saw go down reads identically to a healthy connection from here —
  # see the moduledoc's "A reconnect used to mean silence" section. Only the `:stream`
  # route has anything to re-issue; the `:poll` route re-reads `state.credentials` on its
  # own next tick via `PollingFeed`'s own `fetch` closure, which already needs nothing
  # pushed to it, and `apply_symbols/1`'s `:poll` clause would only repeat the identical
  # `update_symbols/2` call `PollingFeed` already keeps current.
  def handle_info(:resubscribe, %{route: :stream} = state) do
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)

    if MapSet.size(state.wanted) > 0 do
      apply_symbols(state)
    end

    {:noreply, state}
  end

  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)
    {:noreply, state}
  end

  # The other half of `init/1`'s `Process.flag(:trap_exit, true)` — see the moduledoc's
  # "A crashed socket or poller used to be Feed's crash too" section. Matching on
  # `state.socket`/`state.poller` is what tells a real crash apart from an `EXIT` this
  # feed cannot attribute to anything it started; a stale `EXIT` for a pid already
  # replaced falls through to the catch-all below and is correctly ignored.
  def handle_info({:EXIT, pid, reason}, %{socket: pid} = state) do
    {:noreply, isolate_crashed_route(state, reason)}
  end

  def handle_info({:EXIT, pid, reason}, %{poller: pid} = state) do
    {:noreply, isolate_crashed_route(state, reason)}
  end

  # The Streamer bootstrap's HTTP half came back. Everything from here — building the
  # socket, or falling back to the poll — is fast and stays in this process; see the
  # routing section for why the socket must be opened here rather than in the task.
  #
  # Ordered ABOVE the catch-all below, and matched on the stored `ref` so a late reply from
  # a superseded bootstrap cannot settle the current one.
  def handle_info({ref, result}, %{route_bootstrap: %{ref: ref, waiting: waiting}} = state) do
    Process.demonitor(ref, [:flush])

    state = complete_route_bootstrap(%{state | route_bootstrap: nil}, result)
    applied = apply_symbols(state)

    # Every caller parked on this one bootstrap gets the same answer. Replying to a caller
    # that has already timed out is a no-op, so no bookkeeping is needed for that case.
    Enum.each(waiting, &GenServer.reply(&1, applied))

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- routing ------------------------------------------------------------

  # Establishing the Streamer route means a signed `Rest.get_user_preference/2` round trip
  # followed by a WebSocket connect. That used to run INLINE inside `handle_call/3`, which
  # made a subscribe block this GenServer for the whole of it — and with `Core.HttpClient`'s
  # documented defaults (30_000 ms per attempt, 3 attempts) that window reaches roughly
  # ninety seconds. Every read queued behind it: `coverage/1` and `status/1` are plain
  # `GenServer.call/2`s carrying the **five-second** default, so a health check arriving
  # during a subscribe did not merely wait, it EXITED — and a consumer calling it from
  # their own `handle_call/3` died with it.
  #
  # That is dp-exchange-core issue #28's exact failure, which cost a consumer fourteen hours
  # of a dead venue on `dp_exchange_robinhood`, reproduced here on a different venue and a
  # different call. It was found by sweeping this family for the class the #30 reporter
  # named — "work done in the process that owes a reply" — rather than by it failing again
  # in production. Proven before it was fixed: `coverage/1` did not answer within 500 ms
  # while a subscribe was establishing the route.
  #
  # So the slow half runs in a task and the caller's reply is DEFERRED. `dp_exchange_webull`
  # reached the same shape first (`spawn_reconcile/3`), and this is deliberately the same
  # pattern rather than a second invention.
  #
  # **The socket is still opened by this process, not by the task**, and that is not an
  # oversight: `Socket.start_link/1` links to its caller, so opening it inside the task
  # would tie the venue's connection to a process that exits moments later. The task fetches;
  # this GenServer connects. The connect is bounded by `@socket_connect_timeout_ms` (3_000)
  # and is the only part still on the mailbox.

  # Already settled — answer now, with no bootstrap at all.
  defp settle_route(%{route: route} = state, _from) when route in [:stream, :poll],
    do: {:reply, apply_symbols(state), state}

  # A socket supplied at start IS the route already — the injection seam this package's own
  # tests use, and the shape a consumer handing in its own connection takes. No bootstrap
  # runs: `Rest.get_user_preference/2` exists only to discover a socket to open, and one is
  # already open. This was previously `start_socket/1`'s own `when is_pid(socket)` clause;
  # it is load-bearing and moved here with the rest of the routing.
  defp settle_route(%{socket: socket} = state, _from) when is_pid(socket) do
    state = %{state | route: :stream}
    {:reply, apply_symbols(state), state}
  end

  defp settle_route(state, from), do: {:noreply, start_route_bootstrap(state, [from])}

  # A bootstrap is already in flight: join its reply list. Starting a second one would open
  # two Streamer connections for a consumer that merely called `subscribe/2` twice quickly.
  defp start_route_bootstrap(%{route_bootstrap: %{waiting: waiting} = bootstrap} = state, more),
    do: %{state | route_bootstrap: %{bootstrap | waiting: waiting ++ more}}

  defp start_route_bootstrap(state, waiting) do
    credentials = state.credentials
    request_opts = state.request_opts

    task = Task.async(fn -> fetch_user_preference(credentials, request_opts) end)

    %{state | route_bootstrap: %{ref: task.ref, waiting: waiting}}
  end

  # Runs inside the task. Converts a raise or an exit into an ordinary error result BEFORE
  # it can become an abnormal task exit, because `Task.async/1` links: an unconverted
  # exception would reach this Feed as an `{:EXIT, ...}` it has no clause for, and the
  # bootstrap's waiting callers would never be answered at all.
  defp fetch_user_preference(credentials, request_opts) do
    Rest.get_user_preference(credentials, request_opts)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp complete_route_bootstrap(state, {:ok, body}) do
    case build_socket(state, body) do
      {:ok, socket} -> %{state | socket: socket, route: :stream}
      other -> fall_back_to_poll(state, failure_reason(other))
    end
  end

  defp complete_route_bootstrap(state, other),
    do: fall_back_to_poll(state, failure_reason(other))

  defp build_socket(state, body) do
    with {:ok, info} <- StreamerInfo.from_user_preference(body),
         {:ok, token} <- access_token(state.credentials) do
      Socket.start_link(
        Keyword.merge(
          # The timeouts are forwarded so a consumer can tune the connect budget. `Socket`
          # chooses deliberate defaults rather than inheriting websockex's, which do not
          # fit inside this module's own `@call_timeout` — see `Socket.connection_opts/1`.
          Keyword.take(state.opts, [:url, :socket_connect_timeout, :socket_recv_timeout]),
          streamer_info: info,
          access_token: token,
          subscriber: self()
        )
      )
    end
  end

  # `{:refused, …}` and `{:error, …}` are different answers everywhere else in this package
  # and here they are not: the Streamer is unreachable either way, and the remedy — poll,
  # and say so — is the same. The reason travels into the notice, so a consumer can still
  # tell a rejected credential from a network fault.
  #
  # The Streamer could not be bootstrapped. Say so — a consumer reading only `coverage/1`
  # would see `:internal_poll` and have no idea a socket was expected.
  defp fall_back_to_poll(state, reason) do
    notify(
      state,
      Notice.new(:degraded, :schwab,
        details: %{reason: inspect(reason), fallback: :internal_poll}
      )
    )

    start_poller(%{state | last_error: reason})
  end

  # See the moduledoc's "A crashed socket or poller used to be Feed's crash too" section
  # and `handle_info({:EXIT, pid, reason}, %{socket: pid} = state)`/`%{poller: pid}`
  # above. `state.route` is cleared along with `state.socket`/`state.poller` so
  # `ensure_route/1`'s own first clause — `when route in [:stream, :poll], do: state` —
  # does not treat the pid that just died as still live and skip reconnecting entirely.
  # `state.delivering`/`state.kinds` reset because this feed has exactly one active
  # route at a time: whichever one crashed was the only thing delivering.
  defp isolate_crashed_route(state, reason) do
    state = %{state | socket: nil, poller: nil, route: nil, delivering: %{}, kinds: %{}}

    notify(
      state,
      Notice.new(:link_down, :schwab,
        severity: :warning,
        message: "route crashed (#{inspect(reason)}) — reconnecting now",
        details: %{reason: inspect(reason)}
      )
    )

    # Tries the Streamer first and falls back to the poll on failure, exactly like a
    # first-ever bootstrap — a poller crash is not assumed to mean "restart the same
    # route," since the credential that made the Streamer unreachable earlier may have
    # been fixed since (`update_credentials/2`) in the meantime. `apply_symbols/1` is
    # NO LONGER called explicitly here — see the replacement note just below. The old shape
    # was `handle_call({:subscribe, …})` and
    # `handle_call({:update_symbols, …})` both use — because `ensure_route/1`'s own
    # `:stream` branch no longer applies symbols internally; see that function's own
    # comment for why. On the `:poll` branch this is a harmless idempotent re-send:
    # `start_poller/1` already seeded `PollingFeed` with `state.wanted` at start.
    # Nobody is waiting on a `GenServer.call/3` for a crash-triggered reconnect, so the
    # bootstrap starts with an empty reply list. `apply_symbols/1` is no longer called here
    # either: it runs in `handle_info({ref, result}, ...)` once the route is actually
    # settled, which is the only moment it can do anything but return `{:error, :no_route}`.
    start_route_bootstrap(state, [])
  end

  defp failure_reason({:error, reason}), do: reason
  defp failure_reason({:refused, reason}), do: {:refused, reason}
  # No third shape exists — dialyzer proves the two clauses above are total over what
  # `build_socket/2` can return, and a catch-all here would be a branch no input reaches.

  defp access_token(%{access_token: token}) when is_binary(token), do: {:ok, token}
  defp access_token(_credentials), do: {:error, {:missing_credentials, :schwab}}

  defp start_poller(state) do
    subscriber = self()
    credentials = state.credentials
    request_opts = state.request_opts
    snapshot = state.config_snapshot

    result =
      PollingFeed.start_link(
        # Not "schwab" — this label reaches a consumer inside `Core.Notice.message` and
        # `details.label`, and `PollingFeed` only ever runs on this venue's `:poll` route
        # (the Streamer's own health surfaces separately, as `:link_down`/`:link_up` from
        # `Socket`). A plain "schwab" label on a `:coverage_change` notice would read,
        # pasted into an issue with no other context, as if the Streamer itself had gone
        # dark. "schwab-fallback-poll" makes the source unambiguous in the text alone.
        label: "schwab-fallback-poll",
        symbols: MapSet.to_list(state.wanted),
        interval_ms: Config.opt(state.opts, :interval_ms, @interval_ms),
        start_delay_ms: Keyword.get(state.opts, :start_delay_ms),
        sink: fn quote_struct -> send(subscriber, {:dp_exchange, :schwab, quote_struct}) end,
        on_refusal: fn symbol, reason ->
          send(subscriber, {:dp_exchange, :schwab, {:refused, symbol, reason}})
        end,
        # DpCryptoManagement's issue #21: this is the fallback poll's own silent-delivery
        # detector reaching a consumer as data, not just a `Logger.warning` — see this
        # module's moduledoc and `Core.PollingFeed`'s. The `Core.Notice{kind: :coverage_change}`
        # it carries reaches `handle_info({:dp_exchange, :schwab, %Notice{} = notice}, state)`
        # below the same way any other notice from this process does, and fans out to
        # `state.notice_subscribers` — no new clause needed, because that handler is already
        # generic over `kind`.
        on_notice: fn notice -> send(subscriber, {:dp_exchange, :schwab, notice}) end,
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
    # means. `ADD` would accumulate the symbols a caller just removed. A symbol can now
    # reach more than one service (an equity reaches both `LEVELONE_EQUITIES` and
    # `CHART_EQUITY`), so this groups `{service, symbol}` pairs rather than symbols.
    state.wanted
    |> MapSet.to_list()
    |> Enum.flat_map(fn symbol -> Enum.map(services_for(symbol), &{&1, symbol}) end)
    |> Enum.group_by(fn {service, _symbol} -> service end, fn {_service, symbol} -> symbol end)
    |> Enum.each(fn {service, symbols} ->
      Socket.subscribe(socket, service, "SUBS", Enum.map(symbols, &native/1))
    end)

    :ok
  end

  defp apply_symbols(_state), do: {:error, :no_route}

  # Only meaningful on the stream route with a live socket — the poll route re-reads
  # `state.credentials` on its own next tick via the `fetch` closure in `start_poller/1`,
  # which already needs nothing pushed to it. A `nil` or non-binary token is not pushed:
  # `Socket.update_access_token/2` guards on `is_binary/1` itself, so this mirrors that
  # rather than sending something it would reject anyway.
  defp push_access_token(%{route: :stream, socket: socket}, token)
       when is_pid(socket) and is_binary(token) do
    Socket.update_access_token(socket, token)
  end

  defp push_access_token(_state, _token), do: :ok

  # An option symbol reaches `LEVELONE_OPTIONS` only — Schwab publishes no `CHART_OPTIONS`
  # service, so there is no second subscription to add for it. Everything else reaches
  # `LEVELONE_EQUITIES` for quotes and top of book, and `CHART_EQUITY` for one-minute
  # candles: the two services are documented with the identical "Equities symbols in upper
  # case… e.g.: AAPL,TSLA,IBM" key format, so the same symbol set that already reached one
  # reaches the other — no new judgement about which symbols qualify.
  #
  # `NYSE_BOOK`, `NASDAQ_BOOK`, `OPTIONS_BOOK` and `ACCT_ACTIVITY` are deliberately absent
  # from every symbol's list — see the moduledoc's "Three kinds are actually subscribed"
  # section for why wiring either would be a guess, not a fix. `LEVELONE_*` **does not
  # share field numbering** with `CHART_EQUITY` either, so routing a symbol to the wrong
  # service decodes every field against the wrong table and produces prices that are the
  # right shape — `StreamerFields.for_service/1` refuses that per-service, not per-symbol.
  #
  # **`OPTIONS_BOOK` looks like the easy exception and is not** (checked 2026-09-10; the
  # design doc that first said so has been corrected). The routing ambiguity that blocks the
  # equity books genuinely does not apply — one options book service, and
  # `SymbolFormat.option?/1` already answers unambiguously — and the decoder is built and
  # tested, since all three book services share `StreamerFields`' one `@book` table. What
  # blocks it is that **the vendor does not document the key format the book services take
  # for options**: `LEVELONE_OPTIONS` states "Schwab-standard option symbol format:
  # RRRRRRYYMMDDsWWWWWddd", while the shared Book Common table says only "Symbols in upper
  # case and separated by commas. e.g.: AAPL,TSLA,IBM". Sending an option symbol there means
  # assuming the two match — the *new judgement* the paragraph above says this function does
  # not make. A second, independent blocker: `capabilities/0` has no way to say "order book,
  # options only", because `Core.Capabilities`' `streamable` is a flat `[data_kind()]`.
  defp services_for(symbol) do
    if SymbolFormat.option?(symbol) do
      ["LEVELONE_OPTIONS"]
    else
      ["LEVELONE_EQUITIES", "CHART_EQUITY"]
    end
  end

  defp native(symbol) do
    case SymbolFormat.validate(symbol) do
      {:ok, native} -> native
      # A symbol this package will not send to REST is not sent to the socket either. It
      # reaches the venue unchanged and is refused there rather than silently dropped here.
      {:error, _reason} -> symbol
    end
  end

  defp record_delivery(state, %{symbol: symbol} = value) when is_binary(symbol) do
    state = %{
      state
      | delivering: Map.put(state.delivering, symbol, :os.system_time(:millisecond))
    }

    record_kind(state, symbol, value)
  end

  defp record_delivery(state, _value), do: state

  # Kind is read off the decoded value's own struct type, never off a venue service name —
  # `StreamerFields`/`Socket` decode `LEVELONE_*` and `CHART_EQUITY` frames into exactly
  # these three types (confirmed by reading `Socket.decode/4` and `StreamerDecode`), and
  # this is the one place their service names would leak across the facade if this matched
  # on them instead.
  #
  # **`Types.OrderBook` has deliberately no clause here.** `Socket.decode/4` and
  # `StreamerDecode.to_order_book/2` are real and tested, but `services_for/1` never
  # subscribes `NYSE_BOOK`, `NASDAQ_BOOK` or `OPTIONS_BOOK` — see the moduledoc — so no
  # `Types.OrderBook` value can reach this function through the stream route this package
  # actually runs. Adding a `:order_book` mapping anyway would let a value nothing here can
  # produce report a kind `capabilities().streamable` does not declare, which
  # `Core.AdapterContract`'s conformance suite checks for exactly this reason.
  defp record_kind(state, symbol, %Quote{}), do: put_kind(state, symbol, :quotes)
  defp record_kind(state, symbol, %TopOfBook{}), do: put_kind(state, symbol, :top_of_book)
  defp record_kind(state, symbol, %Candle{}), do: put_kind(state, symbol, :candles)
  # A value with a `:symbol` field and no kind mapping — e.g. a bare test map, or (should
  # `services_for/1` ever change) a `Types.OrderBook` — still counts toward `coverage/1`
  # through `delivering` above, but contributes no kind. Nothing this package's own
  # subscriptions produce today reaches this clause; a real one always decodes to one of
  # the three above.
  defp record_kind(state, _symbol, _value), do: state

  defp put_kind(state, symbol, kind) do
    %{
      state
      | kinds: Map.update(state.kinds, symbol, MapSet.new([kind]), &MapSet.put(&1, kind))
    }
  end

  # `Core.Config` resolves through the calling process and its `$callers` chain. A
  # GenServer is in neither, so an override a consumer set for its own async test would be
  # invisible here. Applying the snapshot in whichever process is about to make the request
  # is what carries it across that boundary.
  defp apply_config(snapshot) do
    Enum.each(snapshot, fn {key, value} -> Config.put_override(key, value) end)
  end

  # Refused at `init/1` rather than discovered later, because the failure this prevents is
  # asynchronous and reads as something else entirely.
  #
  # `interval_ms` was passed to `Core.PollingFeed.start_link/1` unchecked, and
  # `PollingFeed` does not validate it either. A negative or fractional value therefore
  # does NOT fail `start_link/1` — it returns `{:ok, pid}` — and crashes later, inside the
  # poller, the first time `Process.send_after/3` is handed the delay. Under this tree's
  # `:one_for_one` strategy a persistently bad option becomes a restart loop rather than a
  # clear refusal at boot, which is the fail-open-then-crash-obscurely shape this family
  # refuses. `DpExchange.Coinbase.Feed`'s `validate_shard_spacing_ms!/1` is the same guard
  # for the same reason; this venue had none.
  #
  # `0` is refused here, unlike Coinbase's shard spacing where zero is a real if extreme
  # choice: a poll interval of zero is not a fast poll, it is a process that reschedules
  # itself with no delay and spends the venue's entire rate budget in one continuous burst.
  defp validate_interval_ms!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_interval_ms!(value) do
    raise ArgumentError,
          "interval_ms must be a positive integer, got: #{inspect(value)}. " <>
            "It is handed to Core.PollingFeed and reaches Process.send_after/3, which " <>
            "would accept neither — but not until the first tick, in another process."
  end

  # A dead subscriber stops delivery. The venue must not accumulate events for a process
  # that no longer exists.
  #
  # A subscriber may be a raw pid or a registered name — `subscribe/2`'s `to:` accepts
  # either, matching ordinary OTP practice (a consumer registering itself by name and
  # handing that name to a producer). `Process.alive?/1` only accepts a pid and raises on
  # anything else, so a registered-name subscriber crashed this whole GenServer on every
  # delivery (same defect, same fix, as `dp-exchange-coinbase`'s `Feed.fan_out/2` —
  # DpCryptoManagement's issue #15). Resolving first, uniformly, fixes both: a dead pid
  # resolves to itself and `Process.alive?/1` filters it; an unregistered name resolves
  # to `nil` and is silently skipped, the same as a dead subscriber already was.
  # A READ must never be able to kill the thing it reads.
  #
  # dp-exchange-core issue #28, reported against `dp_exchange_robinhood` and true here for
  # the same reason: on the `:poll` route these three handlers delegate into `PollingFeed`
  # with `GenServer.call/2`'s default five-second timeout, and that process could not answer
  # while a fetch was in flight — `:fetch_timeout_ms` floors at 30 seconds. A `coverage/1`
  # landing during an ordinary poll was therefore a guaranteed timeout, and the exit
  # propagated out of `handle_call/3` and killed `Feed`, which restarts from static opts
  # that never carry a consumer's later `subscribe/2`. A health check took the venue to
  # zero and left it there, alive and idle, passing every liveness probe.
  #
  # `Core.PollingFeed` no longer blocks on its fetch, which removes that cause. This stays
  # anyway: a poller mid-restart, wedged by something else, or gone is a condition this
  # `Feed` must survive, and no fix inside `PollingFeed` can promise it always answers.
  #
  # The fallbacks say the least that is true. `c:DpExchange.Core.Venue.coverage/1` returns a
  # map, so an error tuple is not sayable there, and an absent symbol already means
  # `:not_covered` — while replying with a REMEMBERED coverage would assert arrivals nobody
  # confirmed, the "nearby substitute where an error belongs" this family keeps paying for.
  # The notice carries what an empty map cannot: **"we could not ask" is not "nothing
  # arrived"**, and only the notice distinguishes them.
  defp poller_read(state, read, fallback) do
    read.()
  catch
    :exit, reason ->
      notify_poller_unresponsive(state, reason)
      fallback
  end

  # `status/1`'s fallback needs a shape, and every field in it is chosen to avoid claiming
  # health we did not observe: `delivering: false` and an explicit `last_error` say plainly
  # that this answer came from a poller that did not respond, rather than from a poll.
  # `symbols` is the one figure that is still genuinely known — it is this `Feed`'s own
  # wanted set, not the poller's.
  defp unresponsive_status(state) do
    %{
      delivering: false,
      symbols: MapSet.size(state.wanted),
      covered: 0,
      failures_since_ok: 0,
      last_error: :poller_unresponsive,
      route: :internal_poll
    }
  end

  # The counterpart to this module's crashed-link notice: that one reports a poller that
  # died, this one a poller that is alive and did not answer. Both would otherwise be the
  # same silent gap in `coverage/1` with nothing explaining it.
  defp notify_poller_unresponsive(state, reason) do
    notice =
      Notice.new(:link_down, :schwab,
        severity: :warning,
        message:
          "poll did not answer a read (#{inspect(reason)}) — reporting no coverage for " <>
            "this read only; the feed is still running",
        details: %{reason: inspect(reason)}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :schwab, notice})
  end

  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case resolve_subscriber(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  defp resolve_subscriber(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp resolve_subscriber(name) when is_atom(name), do: Process.whereis(name)

  defp notify(state, notice) do
    fan_out(
      MapSet.union(state.notice_subscribers, state.subscribers),
      {:dp_exchange, :schwab, notice}
    )
  end
end
