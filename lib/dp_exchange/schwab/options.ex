defmodule DpExchange.Schwab.Options do
  @moduledoc """
  The option keys each facade function reads, in one table, and the refusal of any other.

  A misspelt `limt:` or `fromm:` that is silently ignored answers a different question than
  the caller asked. Every `DpExchange.Schwab` function that takes keyword `opts`, and the
  same function on `DpExchange.Schwab.Fake`, calls `check/2` at the boundary (or `check!/2`
  for the four plain-value reads, which have no error channel). There is one implementation:
  `DpExchange.Core.Options.check/2`, so the answers are the family's:

    * `{:error, {:unknown_option, key}}` - the first key not in the function's list
    * `{:error, {:invalid_options, opts}}` - `opts` is not a keyword list

  The check runs before an internal key (`:limiter`) is added, before anything is sent and
  before the credential is judged. Positional arguments are judged first where they can be
  judged without reading `opts`; where building the answer reads `opts` (an order request
  reads `:session`) the options come first. A function that answers
  `Venue.not_supported()` keeps doing so whatever the options and is not in this table.

  ## What is allowed

  Every function also accepts `:name`, the `name:` its tree was started with: the limiter, the
  order record and the feed are named from it unless `:limiter`, `:order_limit` or `:feed` says
  otherwise.

  A key is allowed on a function only when that function reads it. A key holding `nil` is
  still a key. Two kinds of function:

  **A call that sends an HTTP request** (every REST call and `refresh_credentials/2`) allows
  `DpExchange.Core.Options.transport_options/0` minus the keys it cannot honour, plus the keys
  named in the table below. Each key it allows is forwarded to `Core.HttpClient`
  (`:credentials`, the signing credential, is read from `opts` by the calls that take no
  credential argument). The keys it cannot honour are refused as `{:unknown_option, key}`:

    * `:environment` and `:base_url`, on every request. This venue has one environment and no
      call reads either: the base URLs are `:market_data_url` and `:trader_url`. Accepting a
      `base_url:` that does nothing would send a live token to the production host from a
      caller who believed it had redirected the call.
    * `:retry_attempts` and `:retry_delay` on `place_order/3`, `replace_order/4` and
      `cancel_order/3`: an order write is always exactly one attempt whatever the caller
      passes (Schwab has no idempotency key, so a retry of a write that timed out after the
      venue accepted it could place the order twice), so neither key is read. Any value,
      `0` and `1` included, is `{:error, {:unknown_option, key}}` before anything is sent.
      (`:max_retry_after_s` is read, it clamps the `Retry-After` a 429 penalises the limiter
      for, and is forwarded.)
    * `:retry_attempts` and `:retry_delay` on `refresh_credentials/2`: a refresh spends a
      single-use refresh token and is never retried, whatever the caller asks.

  **A call that sends no request** (`subscribe/2`, `subscribe_notices/1`, `unsubscribe/2`,
  `update_symbols/2`, `update_credentials/2`, `coverage/1`, `wanted/1`, `coverage_by_kind/1`,
  `status/1`) allows only its own keys from the table plus `:credentials`. Every other shared
  transport key (`:timeout`, `:plug`, `:max_body_bytes`, ...) is `{:unknown_option, key}`: it
  could not be read, so accepting it would be a silent no-op. `:credentials` is exempt, as in
  Core's rule: a consumer hands one credential set to every call and an unneeded one changes
  no answer.

  | function | keys beyond the transport keys |
  |---|---|
  | `get_price/2`, `get_top_of_book/2` | `:market_data_url`, `:extra_headers` |
  | `get_historical_prices/4` | market data, `:include_partial`, `:extended_hours`, `:limit` (answers `:unsupported_option`) |
  | `get_symbols/1` | market data, `:query`, `:projection` |
  | `market_status/1` | market data, `:market` |
  | `get_symbol_quote/3` | market data, `:fields` |
  | `get_market/3` | market data, `:date` |
  | `get_instrument/3`, `get_option_expirations/2` | market data |
  | `get_option_chain/2` | market data, `:contractType` and the chain filters (see `Rest.chain_option_keys/0`) |
  | `get_screener/2` | market data, `:sort`, `:frequency` |
  | `get_accounts/2`, `test_connection/2`, `get_user_preference/2`, `get_transaction/4` | `:trader_url`, `:extra_headers` |
  | `get_balances/2`, `get_order/3` | trader, `:account_hash` |
  | `get_account_summaries/2` | trader, `:fields` |
  | `get_positions/1` | trader, `:account_number` |
  | `get_orders/2` | trader, `:account_hash`, `:from`, `:to`, `:status`, `:max_results` |
  | `get_all_orders/2` | trader, `:from`, `:to`, `:status`, `:max_results`, `:now` |
  | `get_transactions/2` | trader, `:account_hash`, `:from`, `:to`, `:types`, `:symbol` |
  | `place_order/3`, `replace_order/4` | trader, `:account_hash`, `:session`, `:order_limit` |
  | `preview_order/3` | trader, `:account_hash`, `:session` |
  | `cancel_order/3` | trader, `:account_hash`, `:order_limit` |
  | `refresh_credentials/2` | `:token_url`, `:now` |
  | `subscribe/2` | `:to`, `:feed`, `:include_partial`, `:limit`, `:depth`, `:since` (the last four answer `:unsupported_option`) |
  | `subscribe_notices/1` | `:to`, `:feed` |
  | `unsubscribe/2`, `update_symbols/2`, `update_credentials/2`, `coverage/1`, `wanted/1`, `coverage_by_kind/1`, `status/1` | `:feed` |

  `DpExchange.Schwab.Fake` adds the keys only it reads, listed in `fake_only/1`.
  """

  alias DpExchange.Core.Options, as: CoreOptions
  alias DpExchange.Schwab.Rest

  @market [:market_data_url, :extra_headers]
  @trader [:trader_url, :extra_headers]
  @write_account [:account_hash, :session]
  @order_filters [:from, :to, :status, :max_results]

  # In Core's shared transport list and read by no Schwab call: one environment, and the base
  # URLs are `:market_data_url` and `:trader_url`. Refused rather than silently ignored.
  @not_read [:environment, :base_url]

  # The order writes, which are sent exactly once whatever the caller passes: neither retry
  # key is read, so both are refused as unknown rather than accepted and overwritten.
  @no_retry [:place_order, :replace_order, :cancel_order]
  @write_not_read [:retry_attempts, :retry_delay]

  # A refresh is never retried (`Auth` forces `retry_attempts: 0`), so neither retry key is read.
  @refresh_not_read [:retry_attempts, :retry_delay]

  # Calls that send no HTTP request: they allow their own keys and `:credentials` only.
  @no_request [
    :subscribe,
    :subscribe_notices,
    :unsubscribe,
    :update_symbols,
    :update_credentials,
    :coverage,
    :wanted,
    :coverage_by_kind,
    :status
  ]

  # The single table. Anything that is not here has no `opts` the facade reads.
  @own %{
    get_price: @market,
    get_top_of_book: @market,
    get_historical_prices: @market ++ [:include_partial, :extended_hours, :limit],
    get_symbols: @market ++ [:query, :projection],
    market_status: @market ++ [:market],
    get_symbol_quote: @market ++ [:fields],
    get_market: @market ++ [:date],
    get_instrument: @market,
    get_option_expirations: @market,
    # Widened in `allowed/1` by the chain filters, which `Rest` owns.
    get_option_chain: @market,
    get_screener: @market ++ [:sort, :frequency],
    get_accounts: @trader,
    test_connection: @trader,
    get_user_preference: @trader,
    get_transaction: @trader,
    get_balances: @trader ++ [:account_hash],
    get_order: @trader ++ [:account_hash],
    get_account_summaries: @trader ++ [:fields],
    get_positions: @trader ++ [:account_number],
    get_orders: @trader ++ [:account_hash | @order_filters],
    get_all_orders: @trader ++ [:now | @order_filters],
    get_transactions: @trader ++ [:account_hash, :from, :to, :types, :symbol],
    place_order: @trader ++ [:order_limit | @write_account],
    replace_order: @trader ++ [:order_limit | @write_account],
    preview_order: @trader ++ @write_account,
    cancel_order: @trader ++ [:account_hash, :order_limit],
    refresh_credentials: [:token_url, :now],
    subscribe: [:to, :feed, :include_partial, :limit, :depth, :since],
    subscribe_notices: [:to, :feed],
    unsubscribe: [:feed],
    update_symbols: [:feed],
    update_credentials: [:feed],
    coverage: [:feed],
    wanted: [:feed],
    coverage_by_kind: [:feed],
    status: [:feed]
  }

  # Keys that only the Fake reads: a seam for a test to steer it. The real facade has no use
  # for them, so on the real facade they stay refused.
  @fake_only %{
    market_status: [:market_status],
    get_market: [:market_status],
    get_accounts: [:account_hash]
  }

  @doc """
  The option keys `function` accepts on the real facade, the transport keys included.
  """
  @spec allowed(atom()) :: [atom()]
  # `:name` is read by every call here: each addresses a process (the limiter, the order record
  # or the feed) whose name is derived from the tree's `name:` unless given explicitly. See
  # `DpExchange.Schwab.Supervisor.limiter_name/1`.
  def allowed(function), do: [:name | allowed_without_name(function)]

  defp allowed_without_name(:get_option_chain), do: allowed_chain()

  defp allowed_without_name(function) when function in @no_request,
    do: [:credentials | Map.fetch!(@own, function)]

  defp allowed_without_name(function), do: transport(function) ++ Map.fetch!(@own, function)

  # **The one table of start keys**: every key `Supervisor` (`:name`, the process-name overrides
  # and the two ceilings), `Feed` (`init/1` and what it forwards to `Socket` and the fallback
  # poll) and the facade's start path read. A start key outside it is refused at the entry
  # point (`start_link/1`, which `child_spec/1` reaches when its supervisor starts the child), not
  # silently ignored: a misspelt `order_limit_per_minut:` would otherwise start a tree that
  # refuses every order write for a reason the caller cannot see, and a misspelt
  # `read_limit_per_minute:` one that runs at a ceiling nobody chose.
  @start_keys [
    # Supervisor
    :name,
    :order_limit_per_minute,
    :read_limit_per_minute,
    :limiter,
    :order_limit,
    :ledger,
    :feed,
    # Feed
    :credentials,
    :symbols,
    :subscriber,
    :interval_ms,
    :start_delay_ms,
    :retry_attempts,
    :rate_limit_blocking,
    :max_queue_len,
    :route_bootstrap_timeout_ms,
    :bootstrap_reply_ms,
    :config_snapshot,
    :socket,
    # Forwarded to the REST calls (`Rest.get_prices/3`, `get_user_preference/2`)
    :plug,
    :req_adapter,
    :market_data_url,
    :trader_url,
    # Forwarded to `Socket.start_link/1`
    :socket_connect_timeout,
    :socket_recv_timeout,
    :url,
    :ssl_options,
    :allow_insecure_socket
  ]

  @doc """
  Every key a tree (`DpExchange.Schwab.start_link/1`, `Supervisor.start_link/1`,
  `Feed.start_link/1`) reads at start. The table `check_start/1` judges against, and
  `usage-rules.md` section 16 lists it.
  """
  @spec start_keys() :: [atom()]
  def start_keys, do: @start_keys

  @doc """
  Checks a start `opts` against `start_keys/0`: `:ok`,
  `{:error, {:unknown_option, key}}` for the first key it does not read (a `nil` value counts), or
  `{:error, {:invalid_options, opts}}` when `opts` is not a keyword list, or
  `{:error, {:invalid_option, :ssl_options}}` for an `:ssl_options` that is not a keyword list
  (the value is never echoed: it may hold a key password). The first two are
  `DpExchange.Core.Options.check/2`'s, which replaces a `:credentials` entry in any `opts` it
  echoes, so a refused start never prints a token.
  """
  @spec check_start(term()) :: :ok | {:error, check_error() | {:invalid_option, :ssl_options}}
  def check_start(opts) do
    with :ok <- CoreOptions.check(opts, start_keys()), do: check_ssl_options(opts)
  end

  # `:ssl_options` is the WebSocket's TLS options (`Socket.connection_opts/1`): `nil` is silence
  # and anything else must be a keyword list. A refusal names the option and never echoes the
  # value, which may carry a `:password` for a private key.
  defp check_ssl_options(opts) do
    case Keyword.get(opts, :ssl_options) do
      nil -> :ok
      tls when is_list(tls) -> if Keyword.keyword?(tls), do: :ok, else: invalid_ssl()
      _other -> invalid_ssl()
    end
  end

  defp invalid_ssl, do: {:error, {:invalid_option, :ssl_options}}

  @doc """
  The extra keys only `DpExchange.Schwab.Fake` reads for `function`, as test seams.
  """
  @spec fake_only(atom()) :: [atom()]
  def fake_only(function), do: Map.get(@fake_only, function, [])

  @doc """
  Checks `opts` against what `function` reads on the real facade.

  `:ok`, `{:error, {:unknown_option, key}}` or `{:error, {:invalid_options, opts}}`.
  """
  @spec check(atom(), term()) :: :ok | {:error, check_error()}
  def check(function, opts) do
    CoreOptions.check(opts, allowed(function))
  end

  @doc """
  As `check/2`, for `DpExchange.Schwab.Fake`: the real list plus `fake_only/1`.
  """
  @spec check_fake(atom(), term()) :: :ok | {:error, check_error()}
  def check_fake(function, opts) do
    CoreOptions.check(opts, allowed(function) ++ fake_only(function))
  end

  @typedoc "What a refused option check answers."
  @type check_error :: {:unknown_option, atom()} | {:invalid_options, term()}

  @doc """
  As `check/2` for the reads that return a plain value and so have no error channel: a
  refusal raises `ArgumentError` instead. An empty answer for bad options would be a
  plausible "nothing covered".
  """
  @spec check!(atom(), term()) :: :ok
  def check!(function, opts) do
    case check(function, opts) do
      :ok ->
        :ok

      {:error, {:unknown_option, key}} ->
        raise ArgumentError, "unknown option #{inspect(key)} for #{function}/1"

      {:error, {:invalid_options, bad}} ->
        raise ArgumentError,
              "opts must be a keyword list, got: " <> inspect(bad, limit: 10, printable_limit: 64)
    end
  end

  defp allowed_chain do
    transport(:get_option_chain) ++ @market ++ [:contractType | Rest.chain_option_keys()]
  end

  defp transport(function),
    do: CoreOptions.transport_options() -- (@not_read ++ not_read(function))

  defp not_read(function) when function in @no_retry, do: @write_not_read
  defp not_read(:refresh_credentials), do: @refresh_not_read
  defp not_read(_function), do: []
end
