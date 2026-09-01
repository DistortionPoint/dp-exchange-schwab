defmodule DpExchange.Schwab.StreamerProtocol do
  @moduledoc """
  The Streamer's wire format: six commands, fifteen services, three kinds of frame.

  Pure functions over maps. **Nothing here opens a socket** — the protocol is separable from
  the transport, and keeping it so is what lets every rule below be tested without one.

  ## SUBS replaces; ADD accumulates

  The venue is explicit and the difference is destructive:

      SUBS A,B,C   then   SUBS A     ->  B and C are unsubscribed. Only A streams.
      ADD  A,B     then   ADD  C     ->  A, B and C all stream.

  **A package that used `SUBS` for an incremental subscribe would silently drop every symbol
  a caller had already asked for**, and the caller would see a feed that simply went quiet
  for them. `subscribe/4` therefore takes the command explicitly rather than defaulting;
  there is no safe default when one choice silently unsubscribes.

  ## Three frame kinds, and only one of them is data

      response   the venue answering a command   (has "response")
      notify     heartbeats and admin notices    (has "notify")
      data       streaming market data            (has "data")

  A caller that treats every frame as data reads a heartbeat as a quote. `classify/1` names
  which is which, and refuses to guess for a frame carrying none of the three keys.

  ## Field numbers, not field names

  The data frames key their content by **number** — `"1"`, `"2"`, `"3"` — and the meaning of
  a number differs per service. `LEVELONE_EQUITIES` field 1 is the bid; `CHART_EQUITY` field
  1 is the open. There is no global table, so each service carries its own, and a field this
  package has no name for is **dropped rather than guessed**: an unknown number decoded as
  the wrong name is a real value in the wrong field.
  """

  alias DpExchange.Schwab.StreamerInfo

  @commands ~w(LOGIN LOGOUT SUBS UNSUBS ADD VIEW)

  @services ~w(
    ADMIN
    LEVELONE_EQUITIES LEVELONE_EQUITY LEVELONE_OPTIONS LEVELONE_FUTURES
    LEVELONE_FUTURES_OPTIONS LEVELONE_FOREX
    NYSE_BOOK NASDAQ_BOOK OPTIONS_BOOK
    CHART_EQUITY CHART_FUTURES
    SCREENER_EQUITY SCREENER_OPTION
    ACCT_ACTIVITY
  )

  @doc "Every command the Streamer accepts, as the venue names them."
  @spec commands() :: [String.t()]
  def commands, do: @commands

  @doc """
  Every service the Streamer carries — fifteen, and the count is the point.

  This package asserted the venue had no streaming API at all. It has these.
  """
  @spec services() :: [String.t()]
  def services, do: @services

  @doc """
  The `ADMIN`/`LOGIN` request, which must succeed before any other command is sent.

  The venue's own note: *"This must be successful before sending other commands."* The
  access token goes in `parameters.Authorization` — **not in a header**, because there are
  no headers on a WebSocket frame, and a package reaching for its REST auth here would send
  a login the venue cannot read.
  """
  @spec login(StreamerInfo.t(), String.t(), pos_integer()) :: map()
  def login(%StreamerInfo{} = info, access_token, request_id) do
    request(info, "ADMIN", "LOGIN", request_id, %{
      "Authorization" => access_token,
      "SchwabClientChannel" => info.channel,
      "SchwabClientFunctionId" => info.function_id
    })
  end

  @doc "The `ADMIN`/`LOGOUT` request. The venue closes the connection on receipt."
  @spec logout(StreamerInfo.t(), pos_integer()) :: map()
  def logout(%StreamerInfo{} = info, request_id),
    do: request(info, "ADMIN", "LOGOUT", request_id, %{})

  @doc """
  A subscription command for `service` over `keys`.

  `command` must be `"SUBS"`, `"ADD"`, `"UNSUBS"` or `"VIEW"` and **has no default** — see
  the moduledoc on why `SUBS` silently unsubscribes.

  `fields` are the venue's field *numbers* for the service, joined as the venue expects.
  Omitting them asks for the service's default set, which differs per service and is the
  venue's choice rather than this package's.
  """
  @spec subscribe(StreamerInfo.t(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def subscribe(%StreamerInfo{} = info, service, command, keys, opts \\ []) do
    with :ok <- known_service(service),
         :ok <- subscription_command(command) do
      parameters =
        %{"keys" => Enum.join(keys, ",")}
        |> put_fields(Keyword.get(opts, :fields))

      {:ok, request(info, service, command, Keyword.get(opts, :request_id, 1), parameters)}
    end
  end

  defp put_fields(parameters, nil), do: parameters
  defp put_fields(parameters, []), do: parameters
  defp put_fields(parameters, fields), do: Map.put(parameters, "fields", Enum.join(fields, ","))

  defp known_service(service) when service in @services, do: :ok
  defp known_service(service), do: {:error, {:unknown_service, service}}

  # LOGIN and LOGOUT are ADMIN commands and are built by their own functions. Accepting one
  # here would produce a subscription request carrying `keys`, which the venue rejects.
  defp subscription_command(command) when command in ~w(SUBS UNSUBS ADD VIEW), do: :ok
  defp subscription_command(command), do: {:error, {:not_a_subscription_command, command}}

  defp request(%StreamerInfo{} = info, service, command, request_id, parameters) do
    %{
      "service" => service,
      "command" => command,
      "requestid" => to_string(request_id),
      "SchwabClientCustomerId" => info.customer_id,
      "SchwabClientCorrelId" => info.correl_id,
      "parameters" => parameters
    }
  end

  @doc """
  Wraps one or more requests in the envelope the venue reads.

  The venue accepts a single request object or a `"requests"` array; this always sends the
  array, so one code path serves both and a batch is never a different shape from a single.
  """
  @spec envelope([map()]) :: map()
  def envelope(requests) when is_list(requests), do: %{"requests" => requests}

  @doc """
  What kind of frame this is.

  Refuses to guess: a frame with none of `response`, `notify` or `data` is
  `{:error, :unrecognised_frame}` rather than being treated as data. A heartbeat read as a
  quote is a price that never traded.
  """
  @spec classify(map()) ::
          {:ok, :response | :notify | :data, list()} | {:error, :unrecognised_frame}
  def classify(%{"data" => data}) when is_list(data), do: {:ok, :data, data}
  def classify(%{"response" => response}) when is_list(response), do: {:ok, :response, response}
  def classify(%{"notify" => notify}) when is_list(notify), do: {:ok, :notify, notify}
  def classify(_frame), do: {:error, :unrecognised_frame}

  @doc """
  Whether a `response` entry says the command succeeded.

  **Code `0` is success and everything else is not.** The venue returns the code inside
  `content`, so a package checking only that a response arrived would treat a rejected
  LOGIN as a successful one and then wait forever for data that never comes.
  """
  @spec succeeded?(map()) :: boolean()
  def succeeded?(%{"content" => %{"code" => 0}}), do: true
  def succeeded?(_response), do: false

  @doc """
  The venue's message for a failed response, or `nil` when it gave none.

  `nil` is not "no error" — `succeeded?/1` answers that. It means the venue refused without
  saying why, which is worth surfacing as itself rather than as an empty string.
  """
  @spec failure_message(map()) :: String.t() | nil
  def failure_message(%{"content" => %{"msg" => msg}}) when is_binary(msg), do: msg
  def failure_message(_response), do: nil

  @doc """
  Renames a data frame's numbered fields using `field_map`, dropping numbers it has no name
  for.

  **Dropping is deliberate.** A field number this package cannot name decoded under a guessed
  name is a real value in the wrong place, and every one of this venue's services numbers its
  fields differently. `"key"` and `"1"`-style keys that are named survive; the rest do not.
  """
  @spec rename(map(), %{String.t() => atom()}) :: map()
  def rename(content, field_map) when is_map(content) and is_map(field_map) do
    for {number, value} <- content,
        name = Map.get(field_map, number),
        not is_nil(name),
        into: %{},
        do: {name, value}
  end
end
