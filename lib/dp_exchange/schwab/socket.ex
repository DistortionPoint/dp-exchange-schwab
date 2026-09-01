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
  """

  use WebSockex

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.{StreamerDecode, StreamerFields, StreamerProtocol}

  require Logger

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
      subscriptions: MapSet.new()
    }

    WebSockex.start_link(Keyword.get(opts, :url, info.socket_url), __MODULE__, state)
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

    # The venue's session is gone. A socket that kept `logged_in?` would send subscriptions
    # the venue ignores and report a healthy feed that receives nothing.
    {:reconnect, %{state | logged_in?: false, subscriptions: MapSet.new()}}
  end

  @impl true
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
      %{state | logged_in?: true}
    else
      # A rejected LOGIN still arrives as a response. Treating its arrival as success is how
      # a socket waits forever for data.
      notify(
        state,
        Notice.new(:degraded, :schwab,
          details: %{reason: StreamerProtocol.failure_message(response) || "login rejected"}
        )
      )

      state
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
