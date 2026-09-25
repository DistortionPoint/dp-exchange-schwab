defmodule DpExchange.Schwab.Socket do
  @moduledoc """
  The venue's **Streamer** — the WebSocket this package spent a year saying did not exist.

  ## LOGIN is a gate, not a greeting

  The vendor: *"Initial request when opening a new connection. This must be successful
  before sending other commands."* So this socket tracks whether login succeeded and
  **refuses to send a subscription before it has**. A package that sent `SUBS` on connect
  would have it silently ignored and then wait for data that never arrives — a failure that
  looks exactly like a quiet market.

  Login is also asynchronous: the frame goes out on connect and the *response* arrives
  later. A command sent in between is held, not put on the wire where the venue would
  drop it — see the next section.

  ## A command sent before LOGIN is held, not dropped

  `subscribe/4` is a cast and always answers `:ok`. This module used to *drop* a command
  that arrived before the LOGIN response, raise a `:degraded` "not logged in" notice, and
  let the `:ok` stand. The reason given was that a caller told a subscription had succeeded
  would wait for data the venue never agreed to send. But the caller had already been told
  `:ok`, and it was the drop that made that untrue.

  It also happened on nearly every start. `WebSockex.start_link/4` runs `handle_connect/2`,
  which queues `:login`, before it returns. `Feed` subscribes the moment `start_link`
  answers, so its `SUBS` reach this mailbox right behind `:login` and are handled a full
  network round trip before the LOGIN response can arrive. Every bootstrap dropped its
  first subscription and raised a spurious `:degraded`. Data began only when `Feed`'s
  periodic re-assert fired, up to a minute later.

  Such a command is now held in `state.held` and sent, in the order asked, in one envelope
  once the LOGIN succeeds. It is validated when it arrives, so one that could never be sent
  is still reported at once. A held `SUBS` supersedes whatever is held for its service
  (`SUBS` replaces that service's whole set on the wire anyway), which bounds the hold by
  the number of services for a caller like `Feed` that only sends `SUBS`. A hard cap of
  64 commands refuses the rest with a `:degraded` notice. A failed LOGIN leaves the
  hold in place for the next connection, since nothing in it was ever sent.

  ## A dead connection is found by pinging it

  A network path can die without either end being told. TCP notices only when it next
  sends, and this socket sends almost nothing once subscribed, so a half-open connection
  stayed "connected", delivering nothing, for as long as the operating system's own
  timeouts allowed. The Streamer does send heartbeat notifies, but the vendor's document
  states no interval for them, so their absence cannot be timed honestly. And on this venue
  delivering nothing overnight is normal, so silence alone proves nothing.

  RFC 6455 gives a signal that needs no venue claim: an endpoint answers a ping with a pong.
  Each connection pings every `@ping_every_ms` (30s), and a frame or a pong counts as being
  heard from. After `@silence_ms` (90s, three pings) with nothing heard, it raises a
  `:degraded` notice (`details.reason: :silent_connection`) and closes. That takes the
  ordinary `handle_disconnect/2` path: `:link_down`, reconnect, LOGIN, re-assert. The check
  carries this connection's ref and a stale one is not re-armed, so reconnects cannot stack
  check chains.

  ## The two identifiers must not change after login

  The venue's error notes list *"client modifies SchwabClientCustomerId or
  SchwabClientCorrelId after logging in"* as a cause of a severed connection. They come from
  `StreamerInfo`, are fixed at `start_link/1`, and there is no way to set them per request.

  ## Reconnection is not resubscription

  `handle_disconnect/2` reconnects and **clears the logged-in flag and the subscriptions**.
  The venue's session is gone; a socket that kept believing it was subscribed would report a
  healthy feed that receives nothing. The `:link_down` notice is what tells a consumer to
  expect the gap, and `:link_up` follows only after login succeeds again — not merely when
  the TCP connection returns.

  ## A rejected LOGIN is not a network blip, and the reconnect backs off

  The vendor's own response-code table marks `3 LOGIN_DENIED` `Connection Severed: Yes` —
  the venue closes the socket itself after refusing a login, which hands this module
  straight back to `handle_disconnect/2` with nothing about the *reason* attached. Left
  alone, that is a reconnect storm waiting to happen: `websockex` reconnects with no delay
  of its own (`deps/websockex/lib/websockex.ex`, `on_disconnect/5` calls `open_connection/3`
  synchronously and loops), so a socket presenting an access token the venue will never
  accept — expired, or simply wrong — would hammer the Streamer at full connect speed,
  forever, since nothing about a repeated `LOGIN_DENIED` fixes itself with time.

  So `state.login_failures` counts consecutive rejected logins, reset to `0` the moment one
  succeeds, and `handle_disconnect/2` sleeps `reconnect_delay_ms/1` of it before reconnecting.
  An ordinary network blip after a healthy session reconnects at once — nothing about it
  suggests the credential is the problem. A `LOGIN_DENIED` is different: this module cannot
  fix its own access token. Only a host calling `DpExchange.Schwab.Auth.refresh/2` — reachable
  through the facade as `DpExchange.Schwab.refresh_credentials/2` — and pushing the result in
  through `update_access_token/2` can do that, and this backoff exists to stop hammering the
  venue while nobody has done so yet — not to fix the credential itself.

  ## A failed LOGIN always ends the connection

  Only `3 LOGIN_DENIED` is certain to be severed by the venue. The same table marks
  `11 SERVICE_NOT_AVAILABLE` `Connection Severed: No` and `9 UNKNOWN_FAILURE` `TBD`. This
  module used to wait for the venue to close the socket after any failed LOGIN, and LOGIN
  is sent only from `handle_connect/2`. So a LOGIN answered with `11` left the socket open
  and never logged in, with nothing that would ever send LOGIN again. `Feed` fans the
  `:degraded` notice out and does nothing else, and every later subscribe got only
  "not logged in". The result was a live connection delivering nothing, indefinitely, which
  is the failure this family ranks worst, and a token refreshed through
  `update_access_token/2` never reached a LOGIN either.

  So `handle_frame/2` answers `{:close, state}` for any failed LOGIN. The local close goes
  through `handle_disconnect/2` like a remote one. It backs off on the `login_failures`
  count the failure just raised, then reconnects and sends a fresh LOGIN with the current
  token. Closing a connection the venue was about to sever anyway (code 3 or 12) costs
  nothing.

  ## The access token can be replaced without a reconnect

  `update_access_token/2` is how a refreshed token reaches an already-running socket. It
  does not force a fresh LOGIN — the current session, if any, is untouched — it only
  replaces what the *next* LOGIN presents, whether that is the next ordinary reconnect or
  the one a backed-off `LOGIN_DENIED` retry eventually attempts. Before this existed, the
  token passed to `start_link/1` was the only one this process would ever hold: a 30-minute
  access token on a socket meant to stay up far longer than that had no path to renewal
  short of tearing the whole feed down and starting over.
  """

  use WebSockex

  alias DpExchange.Core.{Config, Notice, Telemetry}
  alias DpExchange.Schwab.{Credentials, StreamerDecode, StreamerFields, StreamerProtocol}

  require Logger

  # Chosen against `Feed`'s own `@call_timeout` (15s), not inherited.
  #
  # `WebSockex.Conn` defaults to `socket_connect_timeout: 6_000` and
  # `socket_recv_timeout: 5_000` (measured in `deps/websockex/lib/websockex/conn.ex:10-11`),
  # and passing no options silently accepts them. That is 11s of a 15s budget spent on TCP
  # and the HTTP upgrade alone — before this venue's LOGIN round trip, which `Feed` must
  # also fit inside the same call, since the Streamer accepts no subscription until it has
  # answered the login. `Feed` is a named, shared process, so that window is borne by every
  # other consumer's queued call, not only the one that triggered the connect.
  #
  # 3s + 2s leaves real room for the login and first subscribe. Both stay overridable, and
  # setting them changes no failure semantics: `start_link/1` still returns
  # `{:error, reason}` synchronously exactly as before.
  @socket_connect_timeout_ms 3_000
  @socket_recv_timeout_ms 2_000

  # Capped exponential backoff on consecutive LOGIN_DENIED reconnects — see the moduledoc.
  # The first rejection waits a second; each further one doubles, capped well under a
  # minute so a fixed credential recovers quickly rather than being stuck on a long wait
  # from an earlier outage.
  @base_reconnect_delay_ms 1_000
  @max_reconnect_delay_ms 30_000

  # The most commands held while a LOGIN is pending — see the moduledoc's "A command sent
  # before LOGIN is held, not dropped". `Feed` holds at most one per service.
  @max_held 64

  # See the moduledoc's "A dead connection is found by pinging it".
  @ping_every_ms 30_000
  @silence_ms 90_000

  @doc """
  Opens the Streamer for `info`, logging in with `access_token`.

  `:subscriber` receives decoded values and `Core.Notice` events. The socket URL comes from
  `info` and is **not** a constant — see `StreamerInfo`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    info = Keyword.fetch!(opts, :streamer_info)

    state = %{
      info: info,
      # Wrapped immediately — see `Credentials`'s moduledoc. This process holds the
      # token for as long as the Streamer connection is up, and a WebSockex crash
      # prints its state via the same OTP crash report `Feed`'s does.
      credentials: opts |> Keyword.fetch!(:access_token) |> Credentials.wrap_token(),
      subscriber: Keyword.fetch!(opts, :subscriber),
      logged_in?: false,
      request_id: 1,
      # What the caller asked for, so a reconnect can report what was lost rather than
      # pretending it is still live.
      subscriptions: MapSet.new(),
      # Consecutive rejected LOGINs, reset to 0 on the next success. Drives
      # `reconnect_delay_ms/1` — see the moduledoc's "A rejected LOGIN is not a network
      # blip" section.
      login_failures: 0,
      # Whether a LOGIN has ever succeeded here — so only a RE-login is reported to `Feed`.
      # See `report_relogged_in/1`.
      logged_in_once?: false,
      # Commands that arrived before the LOGIN response, sent once it succeeds — see the
      # moduledoc's "A command sent before LOGIN is held, not dropped".
      held: [],
      # When anything, a frame or a pong, last arrived, and this connection's liveness
      # check. See the moduledoc's "A dead connection is found by pinging it".
      last_heard_at: nil,
      liveness: nil,
      # The last book this socket published per symbol, because `LEVELONE_*` is Change
      # delivery — see `merge_top_of_book/3`. Bounded by the symbols subscribed on THIS
      # connection, and dropped wholesale on reconnect.
      last_top: %{}
    }

    WebSockex.start_link(
      Config.opt(opts, :url, info.socket_url),
      __MODULE__,
      state,
      connection_opts(opts)
    )
  end

  @doc """
  The connection options handed to `WebSockex.start_link/4`.

  Exposed so the deliberate timeouts can be asserted without opening a real socket — a
  later refactor must not be able to drop them back to the dependency's defaults unnoticed.
  """
  @spec connection_opts(keyword()) :: keyword()
  def connection_opts(opts) do
    opts
    |> Keyword.take([:socket_connect_timeout, :socket_recv_timeout])
    |> Keyword.put_new(:socket_connect_timeout, @socket_connect_timeout_ms)
    |> Keyword.put_new(:socket_recv_timeout, @socket_recv_timeout_ms)
  end

  @doc """
  Subscribes `keys` on `service` using `command`.

  **`command` has no default.** `SUBS` replaces every prior symbol for the service and `ADD`
  accumulates; see `StreamerProtocol`. Before the LOGIN response has arrived the command is
  held and sent once the login succeeds, because the venue ignores commands sent before it;
  see the moduledoc's "A command sent before LOGIN is held, not dropped" section.
  """
  @spec subscribe(pid(), String.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def subscribe(socket, service, command, keys, opts \\ []) do
    WebSockex.cast(socket, {:subscribe, service, command, keys, opts})
    :ok
  catch
    :exit, _reason -> {:error, :send_timeout}
  end

  @doc """
  Replaces the access token this socket presents at its next `LOGIN`.

  **Does not force a reconnect.** A session already logged in stays logged in; this only
  changes what the *next* `LOGIN` — an ordinary reconnect, or one this module's own
  `LOGIN_DENIED` backoff is about to retry — carries. See the moduledoc: without this,
  the token given to `start_link/1` was the only one the process would ever hold, and a
  30-minute access token on a socket meant to outlive that had nothing to renew it with.

  The caller gets a live token by calling `DpExchange.Schwab.Auth.refresh/2` — reachable
  through the facade as `DpExchange.Schwab.refresh_credentials/2` — and passing the result
  here, or through `DpExchange.Schwab.Feed.update_credentials/2`, which does both.
  """
  @spec update_access_token(pid(), String.t()) :: :ok | {:error, term()}
  def update_access_token(socket, access_token) when is_binary(access_token) do
    WebSockex.cast(socket, {:update_access_token, access_token})
    :ok
  catch
    :exit, _reason -> {:error, :send_timeout}
  end

  @doc """
  The delay, in milliseconds, before reconnecting after `failures` consecutive rejected
  `LOGIN`s.

  **Zero failures waits zero.** An ordinary disconnect after a healthy session — a network
  blip, the venue's own idle timeout — reconnects at once, because nothing about it
  suggests the credential is the problem. Every rejection after the first doubles the
  wait, capped at #{@max_reconnect_delay_ms}ms, because a `LOGIN_DENIED` (`Response Code
  3` in the vendor's own table, `Connection Severed: Yes`) means the venue will keep
  severing the connection for exactly as long as this process keeps presenting the same
  access token — and reconnecting at full speed against a credential that cannot work is
  the reconnect storm this function exists to prevent.
  """
  # Integer shifting, not `:math.pow/2`, and the exponent is clamped BEFORE the shift.
  #
  # `:math.pow(2, n)` is float arithmetic and raises `ArithmeticError` once `n` passes 1023,
  # because the float range ends at ~1.8e308. Clamping the RESULT — which is what
  # `min(base * pow, max)` did — does not help: the raise happens while computing the
  # argument to `min/2`. So this function crashed during exactly the storm it was written to
  # survive, at roughly the 1025th consecutive rejection.
  #
  # That is not hypothetical here, it is this function's own stated scenario. The moduledoc
  # says a `LOGIN_DENIED` "means the venue will keep severing the connection for exactly as
  # long as this process keeps presenting the same access token", and only a host calling
  # `Auth.refresh/2` can change that. At the 30-second cap, 1025 rejections is about 8.5
  # hours — an access token that expired overnight with nobody on hand to refresh it, which
  # is precisely the case this backoff exists for. The crash then lands inside
  # `handle_disconnect/2`, reading as this socket's fault rather than the credential's.
  #
  # Found while giving the other three WebSocket venues the backoff they had none of: the
  # arithmetic was copied there, and writing a test for a large attempt number caught it in
  # all four at once.
  #
  # `Bitwise.bsl/2` has no such ceiling and is exact. The clamp exists only so the
  # intermediate cannot grow without bound — the cap is already reached at exponent 5
  # (`2^5 * @base_reconnect_delay_ms` exceeds `@max_reconnect_delay_ms`), so every clamped
  # value produces the identical answer the unclamped one would have.
  @max_backoff_exponent 30

  @spec reconnect_delay_ms(non_neg_integer()) :: non_neg_integer()
  def reconnect_delay_ms(0), do: 0

  def reconnect_delay_ms(failures) when is_integer(failures) and failures > 0 do
    exponent = min(failures - 1, @max_backoff_exponent)

    min(@base_reconnect_delay_ms * Bitwise.bsl(1, exponent), @max_reconnect_delay_ms)
  end

  # --- callbacks ----------------------------------------------------------

  @impl true
  def handle_connect(_conn, state) do
    # `handle_connect/2` cannot reply — the behaviour returns `{:ok, state}` only — so the
    # LOGIN frame is sent from `handle_info/2` a moment later. That is a transport detail,
    # not a delay a caller can observe: a `subscribe/5` before the login *response* is held
    # and sent once it arrives, regardless.
    #
    # The link is up and the session is not. `:link_up` waits for that response —
    # announcing it here would tell a consumer the feed is live while the venue is still
    # ignoring every command.
    send(self(), :login)

    liveness = make_ref()
    schedule_liveness(liveness)
    {:ok, %{state | last_heard_at: now_ms(), liveness: liveness}}
  end

  @impl true
  def handle_info(:login, state) do
    login = StreamerProtocol.login(state.info, state.credentials.access_token, state.request_id)
    frame = Jason.encode!(StreamerProtocol.envelope([login]))

    {:reply, {:text, frame}, %{state | request_id: state.request_id + 1}}
  end

  # See the moduledoc's "A dead connection is found by pinging it". A check whose ref is not
  # this connection's belongs to one that has since dropped, and is not re-armed.
  def handle_info({:liveness, liveness}, %{liveness: liveness} = state) do
    silent_for = now_ms() - state.last_heard_at

    if silent_for >= @silence_ms do
      notify(
        state,
        Notice.new(:degraded, :schwab,
          message:
            "nothing heard, not even a pong, for #{silent_for}ms — closing the connection " <>
              "and reconnecting",
          details: %{reason: :silent_connection, silent_for_ms: silent_for}
        )
      )

      {:close, %{state | liveness: nil}}
    else
      schedule_liveness(liveness)
      {:reply, :ping, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_pong(_frame, state), do: {:ok, %{state | last_heard_at: now_ms()}}

  defp schedule_liveness(liveness),
    do: Process.send_after(self(), {:liveness, liveness}, @ping_every_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    notify(state, Notice.new(:link_down, :schwab, details: %{reason: inspect(reason)}))
    Telemetry.link_down(:schwab, inspect(reason))

    # See the moduledoc's "A rejected LOGIN is not a network blip" section. `websockex`
    # reconnects immediately with no delay of its own, and a socket presenting an access
    # token the venue will never accept would otherwise hammer the Streamer at full connect
    # speed, forever. Zero consecutive failures waits zero, so an ordinary network blip
    # after a healthy session still reconnects at once.
    delay = reconnect_delay_ms(state.login_failures)

    # This venue is the ONLY one in the family that emits `link_reconnect_attempt`, and the
    # reason is that it is the only one with a real attempt counter. `login_failures` is
    # consecutive rejected logins, reset to zero the moment one succeeds, so the number here
    # means something: a consumer watching this event sees the backoff climbing and can tell
    # a socket that cannot get back from one that flapped once. The other four reconnect
    # immediately and keep no counter — they would have to report `attempt: 1` every time,
    # which renders a reconnect loop as an endless series of first attempts. An invented
    # counter is exactly the plausible-wrong-value this family keeps writing rules against,
    # so they emit `:link, :down` and nothing else.
    Telemetry.link_reconnect_attempt(:schwab, state.login_failures + 1, delay)

    if delay > 0, do: Process.sleep(delay)

    # The venue's session is gone. A socket that kept `logged_in?` would send subscriptions
    # the venue ignores and report a healthy feed that receives nothing.
    # `last_top` goes with the subscriptions, and for the same reason. A book carried across
    # this boundary would be this package continuing to assert a level on behalf of a session
    # the venue no longer has; the fresh session re-states what is true when it resubscribes.
    {:reconnect, %{state | logged_in?: false, subscriptions: MapSet.new(), last_top: %{}}}
  end

  @impl true
  def handle_cast({:update_access_token, access_token}, state),
    do: {:ok, %{state | credentials: Credentials.wrap_token(access_token)}}

  # Held until LOGIN succeeds, not dropped — see the moduledoc's "A command sent before
  # LOGIN is held, not dropped" section. Validated now so a command that could never be
  # sent is reported at once rather than after the login.
  def handle_cast({:subscribe, service, command, keys, opts}, %{logged_in?: false} = state) do
    case StreamerProtocol.subscribe(state.info, service, command, keys, opts) do
      {:ok, _request} ->
        {:ok, hold(state, {service, command, keys, opts})}

      {:error, reason} ->
        notify(state, Notice.new(:degraded, :schwab, details: %{reason: inspect(reason)}))
        {:ok, state}
    end
  end

  def handle_cast({:subscribe, service, command, keys, opts}, state) do
    case StreamerProtocol.subscribe(
           state.info,
           service,
           command,
           keys,
           Keyword.put(opts, :request_id, state.request_id)
         ) do
      {:ok, request} ->
        frame = Jason.encode!(StreamerProtocol.envelope([request]))

        {:reply, {:text, frame},
         %{
           state
           | request_id: state.request_id + 1,
             subscriptions: MapSet.put(state.subscriptions, {service, keys})
         }}

      {:error, reason} ->
        notify(state, Notice.new(:degraded, :schwab, details: %{reason: inspect(reason)}))
        {:ok, state}
    end
  end

  def handle_cast(_other, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, raw}, state) do
    state = %{state | last_heard_at: now_ms()}
    # Emitted BEFORE the decode, and counted whether or not it parses — the question this
    # event answers is "is the venue sending", and a frame this package could not read is
    # still a frame the venue sent. Counting only what parsed would make a decoder bug here
    # look like a silent venue, which on this venue is especially costly: delivering nothing
    # overnight is the NORMAL state, so a real outage and a quiet market already look alike.
    Telemetry.link_event(:schwab, :frame, byte_size(raw))

    case Jason.decode(raw) do
      {:ok, frame} -> handle_decoded(frame, state)
      # A frame this package cannot parse is dropped rather than crashing the socket: one
      # malformed message must not take down a live feed.
      {:error, _reason} -> {:ok, state}
    end
  end

  def handle_frame(_other, state), do: {:ok, state}

  defp handle_decoded(frame, state) do
    case StreamerProtocol.classify(frame) do
      {:ok, :response, responses} ->
        after_responses(Enum.reduce(responses, state, &handle_response/2), state)

      {:ok, :data, entries} ->
        {:ok, Enum.reduce(entries, state, &handle_data/2)}

      # Heartbeats. Not data, and reading one as a quote is a price that never traded.
      {:ok, :notify, _notices} ->
        {:ok, state}

      {:error, :unrecognised_frame} ->
        {:ok, state}
    end
  end

  # A failed LOGIN ends the connection from this side, whatever its code — see the
  # moduledoc's "A failed LOGIN always ends the connection" section.
  defp after_responses(%{login_failures: failures} = state, %{login_failures: before})
       when failures > before,
       do: {:close, state}

  # The LOGIN just succeeded: everything held while it was pending goes out now, as one
  # envelope, in the order it was asked for.
  defp after_responses(%{logged_in?: true, held: [_first | _rest]} = state, %{logged_in?: false}),
    do: release_held(state)

  defp after_responses(state, _before), do: {:ok, state}

  # `SUBS` replaces the service's whole symbol set on the wire, so a held `SUBS` makes every
  # command held before it for the same service moot. Dropping them keeps what is sent
  # identical in effect to sending each in turn, and keeps the hold bounded by the number of
  # services when, as `Feed` does, a caller only ever sends `SUBS`.
  defp hold(state, {service, "SUBS", _keys, _opts} = command) do
    kept =
      Enum.reject(state.held, fn {held_service, _command, _keys, _opts} ->
        held_service == service
      end)

    hold_within_limit(%{state | held: kept}, command)
  end

  defp hold(state, command), do: hold_within_limit(state, command)

  defp hold_within_limit(%{held: held} = state, command) when length(held) < @max_held,
    do: %{state | held: held ++ [command]}

  defp hold_within_limit(state, _command) do
    notify(
      state,
      Notice.new(:degraded, :schwab,
        details: %{reason: "#{@max_held} commands already held awaiting LOGIN; this one refused"}
      )
    )

    state
  end

  defp release_held(state) do
    {requests, state} =
      Enum.reduce(state.held, {[], %{state | held: []}}, fn {service, command, keys, opts},
                                                            {requests, state} ->
        {:ok, request} =
          StreamerProtocol.subscribe(
            state.info,
            service,
            command,
            keys,
            Keyword.put(opts, :request_id, state.request_id)
          )

        {[request | requests],
         %{
           state
           | request_id: state.request_id + 1,
             subscriptions: MapSet.put(state.subscriptions, {service, keys})
         }}
      end)

    frame = Jason.encode!(StreamerProtocol.envelope(Enum.reverse(requests)))
    {:reply, {:text, frame}, state}
  end

  defp handle_response(%{"service" => "ADMIN", "command" => "LOGIN"} = response, state) do
    if StreamerProtocol.succeeded?(response) do
      notify(state, Notice.new(:link_up, :schwab))

      # Here and not in `handle_connect/2`, for the reason that callback already gives: the
      # WebSocket being up is the transport, and the LINK is the venue accepting the LOGIN.
      # Emitting on connect would report a live venue for a socket the Streamer is ignoring
      # — the transport-vs-link confusion `Core.Telemetry`'s "Why the category is `:link` and
      # not `:ws`" section exists to prevent.
      #
      # The metrics channel alongside the notice channel, never instead of it: a
      # `Core.Notice` is a condition a consumer must ACT on, telemetry is aggregate and
      # lossy by design.
      Telemetry.link_up(:schwab)

      if state.logged_in_once?, do: report_relogged_in(state)

      # Reset the streak. A success proves the access token this process currently holds
      # works, so the next disconnect — whatever causes it — is presumed innocent again.
      %{state | logged_in?: true, login_failures: 0, logged_in_once?: true}
    else
      # A rejected LOGIN still arrives as a response. Treating its arrival as success is how
      # a socket waits forever for data.
      #
      # **The kind is chosen from the venue's own code, not flattened to one.** A
      # `LOGIN_DENIED` is the venue rejecting this credential, and the vendor's response-code
      # table answers it with "reconnect and re-login with new token" — an instruction a host
      # can act on automatically, which is exactly what `:credentials_rejected` exists to
      # carry. `Core.Notice`'s own moduledoc calls that kind close to load-bearing, because a
      # consumer whose keys stopped working otherwise learns it from the absence of data,
      # the slowest possible signal. Reporting it as `:degraded` with the reason in a free
      # text string left nothing to pattern-match on: this package refreshes only when the
      # host calls `DpExchange.Schwab.refresh_credentials/2`, so a host that cannot recognise
      # "your credential was refused" has no trigger to call it, and the socket backs off and
      # retries the same dead token until someone reads a log by hand. The same collapsing
      # mistake `{:error, :oversubscribed}` was named separately to avoid in the Webull
      # package.
      #
      # Every OTHER login failure stays `:degraded`, deliberately: the vendor's `9
      # UNKNOWN_FAILURE` is its error-of-last-resort and `11 SERVICE_NOT_AVAILABLE` is the
      # venue being down. A new token is not the remedy for either, and claiming a credential
      # was rejected when the venue never said so is the substitution this family fails
      # closed against.
      kind =
        if StreamerProtocol.login_denied?(response), do: :credentials_rejected, else: :degraded

      notify(
        state,
        Notice.new(kind, :schwab,
          details: %{reason: StreamerProtocol.failure_message(response) || "login rejected"}
        )
      )

      # Counted here, not in `handle_disconnect/2`: this response is what causes the
      # disconnect that follows (`after_responses/2` closes on it), and
      # `reconnect_delay_ms/1` reads the count from the state this response leaves behind.
      %{state | login_failures: state.login_failures + 1}
    end
  end

  defp handle_response(response, state) do
    unless StreamerProtocol.succeeded?(response) do
      notify(
        state,
        Notice.new(:degraded, :schwab,
          details: %{
            service: response["service"],
            reason: StreamerProtocol.failure_message(response) || "command rejected"
          }
        )
      )
    end

    state
  end

  defp handle_data(%{"service" => service, "content" => content}, state)
       when is_list(content) do
    observed_at = DateTime.utc_now()

    case StreamerFields.for_service(service) do
      {:ok, field_map} ->
        Enum.reduce(content, state, &emit(&1, service, field_map, observed_at, &2))

      # A service with no field map is left undecoded rather than decoded with another's
      # numbering. Silence here is correct; a wrong field is not.
      {:error, _reason} ->
        state
    end
  end

  defp handle_data(_entry, state), do: state

  defp emit(row, service, field_map, observed_at, state) do
    fields = StreamerProtocol.rename(row, field_map)
    symbol = Map.get(fields, :symbol) || row["key"]
    {values, state} = decode(service, fields, symbol, observed_at, state)

    Enum.each(values, &notify(state, &1))
    state
  end

  # A LEVELONE frame is two facts at once, so both are emitted: the quote only when the
  # venue reported a traded price, and the top of book always.
  defp decode("LEVELONE_" <> _rest, fields, symbol, observed_at, state) do
    quote_result = StreamerDecode.to_quote(fields, symbol, observed_at)
    {:ok, delta} = StreamerDecode.to_top_of_book(fields, symbol, observed_at)

    top = merge_top_of_book(Map.get(state.last_top, symbol), delta, fields)
    state = put_in(state.last_top[symbol], top)

    case quote_result do
      {:ok, quote_struct} -> {[quote_struct, top], state}
      # No traded price. The top of book still stands; a quote would have to invent one.
      {:error, _reason} -> {[top], state}
    end
  end

  defp decode("CHART_" <> _rest, fields, symbol, _observed_at, state) do
    case StreamerDecode.to_candle(fields, symbol, "1m") do
      {:ok, candle} -> {[candle], state}
      {:error, _reason} -> {[], state}
    end
  end

  defp decode(book, fields, symbol, _observed_at, state)
       when book in ~w(NYSE_BOOK NASDAQ_BOOK OPTIONS_BOOK) do
    case StreamerDecode.to_order_book(fields, symbol) do
      {:ok, order_book} -> {[order_book], state}
      {:error, _reason} -> {[], state}
    end
  end

  # ACCT_ACTIVITY and the screeners have field maps but no value type in this contract yet.
  # Emitting the renamed map would hand a consumer a shape the facade never promised.
  defp decode(_service, _fields, _symbol, _observed_at, state), do: {[], state}

  # `LEVELONE_*` is **Change** delivery. The vendor's own service table gives that type to
  # `LEVELONE_EQUITIES`, `LEVELONE_OPTIONS`, `LEVELONE_FUTURES` and
  # `LEVELONE_FUTURES_OPTIONS`, and defines it as *"Only fields that clients are interested
  # in, and have changed, are streamed to the client. Data is conflated by the streamer."*
  # A frame there is a DELTA: what it omits is what did not move.
  #
  # `Core.Types.TopOfBook` says something incompatible about an absent level — *"An illiquid
  # instrument can genuinely have no resting bid, and a venue that says so is telling the
  # truth"* — and about an absent size, *"`nil` means 'not published', never 'none
  # available'"*. Publishing a delta straight through therefore made a factual claim about
  # the book on the venue's behalf that the venue had not made, and on a liquid equity it was
  # false on every frame that moved only one side. Every value in it was real; only the
  # meaning was wrong, which is the failure this family names as its recurring one.
  #
  # So the delta is merged onto what this socket last published for that symbol, and the
  # SNAPSHOT is what crosses the facade. That is also what the facade requires: a consumer
  # able to tell a Change service from an All Sequence one by the shape of its values is a
  # consumer who can see how this venue works.
  #
  # Presence, not value, decides — `StreamerProtocol.rename/2` builds its map only from the
  # field numbers the frame actually carried, so a key here means the venue spoke. A field
  # that is present but unreadable (a NaN, which `StreamerDecode` turns into `nil` and has
  # its own guard and tests) is NOT carried forward: the venue said something this package
  # could not read, and answering with the previous value would be inventing an answer to a
  # question that was actually asked.
  defp merge_top_of_book(nil, delta, _fields), do: delta

  defp merge_top_of_book(previous, delta, fields) do
    Enum.reduce([:bid, :ask, :bid_size, :ask_size], delta, fn field, merged ->
      if Map.has_key?(fields, field),
        do: merged,
        else: Map.put(merged, field, Map.get(previous, field))
    end)
  end

  defp notify(%{subscriber: subscriber}, payload),
    do: send(subscriber, {:dp_exchange, :schwab, payload})

  # A reconnect clears the venue's subscriptions (see "Reconnection is not
  # resubscription"), and `Feed` re-asserts on a 60s timer regardless, which left up to a
  # minute of silence after every ordinary reconnect. This tells `Feed` once the new LOGIN
  # has SUCCEEDED, the first moment a `SUBS` can land, so it can re-assert now. The first
  # login is not reported, because what `Feed` asked for before it is held and released by
  # `release_held/1`. A private message rather than a `Core.Notice`, because it carries this
  # socket's pid, which a consumer has no use for.
  defp report_relogged_in(%{subscriber: subscriber}) when is_pid(subscriber) do
    send(subscriber, {:dp_exchange, :schwab, :relogged_in, self()})
    :ok
  end

  defp report_relogged_in(_state), do: :ok
end
