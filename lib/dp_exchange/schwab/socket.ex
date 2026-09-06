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
  later, so `subscribe/4` before that response is `{:error, :not_logged_in}` rather than a
  frame the venue drops.

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

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.{StreamerDecode, StreamerFields, StreamerProtocol}

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
      access_token: Keyword.fetch!(opts, :access_token),
      subscriber: Keyword.fetch!(opts, :subscriber),
      logged_in?: false,
      request_id: 1,
      # What the caller asked for, so a reconnect can report what was lost rather than
      # pretending it is still live.
      subscriptions: MapSet.new(),
      # Consecutive rejected LOGINs, reset to 0 on the next success. Drives
      # `reconnect_delay_ms/1` — see the moduledoc's "A rejected LOGIN is not a network
      # blip" section.
      login_failures: 0
    }

    WebSockex.start_link(
      Keyword.get(opts, :url, info.socket_url),
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
  accumulates; see `StreamerProtocol`. Returns `{:error, :not_logged_in}` when the login
  response has not arrived, because the venue ignores commands sent before it.
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
  @spec reconnect_delay_ms(non_neg_integer()) :: non_neg_integer()
  def reconnect_delay_ms(0), do: 0

  def reconnect_delay_ms(failures) when is_integer(failures) and failures > 0 do
    min(@base_reconnect_delay_ms * round(:math.pow(2, failures - 1)), @max_reconnect_delay_ms)
  end

  # --- callbacks ----------------------------------------------------------

  @impl true
  def handle_connect(_conn, state) do
    # `handle_connect/2` cannot reply — the behaviour returns `{:ok, state}` only — so the
    # LOGIN frame is sent from `handle_info/2` a moment later. That is a transport detail,
    # not a delay a caller can observe: `subscribe/5` refuses until the login *response*
    # arrives regardless.
    #
    # The link is up and the session is not. `:link_up` waits for that response —
    # announcing it here would tell a consumer the feed is live while the venue is still
    # ignoring every command.
    send(self(), :login)
    {:ok, state}
  end

  @impl true
  def handle_info(:login, state) do
    login = StreamerProtocol.login(state.info, state.access_token, state.request_id)
    frame = Jason.encode!(StreamerProtocol.envelope([login]))

    {:reply, {:text, frame}, %{state | request_id: state.request_id + 1}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    notify(state, Notice.new(:link_down, :schwab, details: %{reason: inspect(reason)}))

    # See the moduledoc's "A rejected LOGIN is not a network blip" section. `websockex`
    # reconnects immediately with no delay of its own, and a socket presenting an access
    # token the venue will never accept would otherwise hammer the Streamer at full connect
    # speed, forever. Zero consecutive failures waits zero, so an ordinary network blip
    # after a healthy session still reconnects at once.
    case reconnect_delay_ms(state.login_failures) do
      0 -> :ok
      delay -> Process.sleep(delay)
    end

    # The venue's session is gone. A socket that kept `logged_in?` would send subscriptions
    # the venue ignores and report a healthy feed that receives nothing.
    {:reconnect, %{state | logged_in?: false, subscriptions: MapSet.new()}}
  end

  @impl true
  def handle_cast({:update_access_token, access_token}, state),
    do: {:ok, %{state | access_token: access_token}}

  def handle_cast({:subscribe, _service, _command, _keys, _opts}, %{logged_in?: false} = state) do
    # Dropped deliberately rather than queued: a caller told the subscription succeeded
    # would wait for data the venue never agreed to send.
    notify(state, Notice.new(:degraded, :schwab, details: %{reason: "not logged in"}))
    {:ok, state}
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
      {:ok, :response, responses} -> {:ok, Enum.reduce(responses, state, &handle_response/2)}
      {:ok, :data, entries} -> {:ok, Enum.reduce(entries, state, &handle_data/2)}
      # Heartbeats. Not data, and reading one as a quote is a price that never traded.
      {:ok, :notify, _notices} -> {:ok, state}
      {:error, :unrecognised_frame} -> {:ok, state}
    end
  end

  defp handle_response(%{"service" => "ADMIN", "command" => "LOGIN"} = response, state) do
    if StreamerProtocol.succeeded?(response) do
      notify(state, Notice.new(:link_up, :schwab))
      # Reset the streak. A success proves the access token this process currently holds
      # works, so the next disconnect — whatever causes it — is presumed innocent again.
      %{state | logged_in?: true, login_failures: 0}
    else
      # A rejected LOGIN still arrives as a response. Treating its arrival as success is how
      # a socket waits forever for data.
      notify(
        state,
        Notice.new(:degraded, :schwab,
          details: %{reason: StreamerProtocol.failure_message(response) || "login rejected"}
        )
      )

      # Counted here, not in `handle_disconnect/2`: the venue's own table marks
      # `LOGIN_DENIED` `Connection Severed: Yes`, so this response is what causes the
      # disconnect that follows, and `reconnect_delay_ms/1` reads the count from the state
      # this response leaves behind.
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
        Enum.each(content, &emit(&1, service, field_map, observed_at, state))
        state

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

    for value <- decode(service, fields, symbol, observed_at) do
      notify(state, value)
    end
  end

  # A LEVELONE frame is two facts at once, so both are emitted: the quote only when the
  # venue reported a traded price, and the top of book always.
  defp decode("LEVELONE_" <> _rest, fields, symbol, observed_at) do
    quote_result = StreamerDecode.to_quote(fields, symbol, observed_at)
    {:ok, top} = StreamerDecode.to_top_of_book(fields, symbol, observed_at)

    case quote_result do
      {:ok, quote_struct} -> [quote_struct, top]
      # No traded price. The top of book still stands; a quote would have to invent one.
      {:error, _reason} -> [top]
    end
  end

  defp decode("CHART_" <> _rest, fields, symbol, _observed_at) do
    case StreamerDecode.to_candle(fields, symbol, "1m") do
      {:ok, candle} -> [candle]
      {:error, _reason} -> []
    end
  end

  defp decode(book, fields, symbol, _observed_at)
       when book in ~w(NYSE_BOOK NASDAQ_BOOK OPTIONS_BOOK) do
    case StreamerDecode.to_order_book(fields, symbol) do
      {:ok, order_book} -> [order_book]
      {:error, _reason} -> []
    end
  end

  # ACCT_ACTIVITY and the screeners have field maps but no value type in this contract yet.
  # Emitting the renamed map would hand a consumer a shape the facade never promised.
  defp decode(_service, _fields, _symbol, _observed_at), do: []

  defp notify(%{subscriber: subscriber}, payload),
    do: send(subscriber, {:dp_exchange, :schwab, payload})
end
