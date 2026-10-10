defmodule DpExchange.Schwab.SpecExamplesTest do
  @moduledoc """
  Every endpoint and Streamer service this package calls or decodes, driven by the
  vendor's own documented example — or, where the vendor publishes none, an instance
  built strictly from the schema's own properties and JSON types.

  ## Why this file exists

  This family's worst bugs have come from a test fixture written to agree with the code
  instead of with the vendor — a hand-typed body that happens to satisfy whatever the
  decoder currently does, so a real mismatch between the two never has anywhere to
  surface. Every fixture here traces to a citation in
  `test/fixtures/spec_examples/README.md`: a line in one of the two committed OpenAPI
  documents, or a line in the committed Streamer guide. Nothing is invented by reading
  the implementation and working backwards.

  Each test drives the **real public function** — `DpExchange.Schwab.*` where the facade
  exists, `Rest`/`Orders`/`StreamerInfo` directly where the facade has no narrower
  callback (`Rest.get_symbol_quote/3`, `Orders.build/2`, and so on) — through the same
  `plug:` seam the rest of this suite already uses, and asserts both sides: the request
  built from the venue's own documented parameters, and the value decoded from the
  venue's own documented response.

  Where a spec-example test found a real mismatch between this package and the vendor's
  own document, the code was fixed rather than the test bent to match it — see the
  comment beside each fix, and `CHANGELOG.md`.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config

  alias DpExchange.Core.Types.{
    Balance,
    Candle,
    OptionChain,
    Order,
    Position,
    Quote,
    ScreenerResult,
    TopOfBook
  }

  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Rest, StreamerDecode, StreamerFields, StreamerInfo, StreamerProtocol}

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @creds %{access_token: "at-1"}

  @fixtures_dir Path.expand("../../fixtures/spec_examples", __DIR__)

  defp fixture!(relative_path) do
    @fixtures_dir
    |> Path.join(relative_path)
    |> File.read!()
    |> Jason.decode!()
  end

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp capturing(body, status \\ 200) do
    test_pid = self()

    fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string})
      Req.Test.json(%{conn | status: status}, body)
    end
  end

  defp capturing_body(status, resp_body, headers \\ []) do
    test_pid = self()

    fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, Jason.decode!(raw_body)})

      conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
      Req.Test.json(%{conn | status: status}, resp_body)
    end
  end

  # ============================================================================
  # Market data — GET /quotes (MD:88, components.examples.MultiCriteriaSearch, MD:1038)
  # ============================================================================

  describe "GET /quotes — quotes_multi_criteria_search.json (MultiCriteriaSearch, AAPL)" do
    setup do
      body = fixture!("market_data/quotes_multi_criteria_search.json")
      %{body: body}
    end

    test "get_price/2 reads lastPrice, totalVolume and tradeTime exactly as the vendor sent them",
         %{
           body: body
         } do
      assert {:ok, %Quote{} = quoted} =
               Schwab.get_price("AAPL",
                 credentials: @creds,
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert quoted.symbol == "AAPL"
      assert Decimal.equal?(quoted.price, Decimal.from_float(168.405))
      assert Decimal.equal?(quoted.volume, Decimal.new(22_361_159))
      # The price is `lastPrice`, a trade, so it is dated by `tradeTime` (408ms), not the
      # later `quoteTime` (672ms) the vendor's example also carries — see get_price/3's @doc.
      assert quoted.venue_time == DateTime.from_unix!(1_644_854_683_408, :millisecond)
      assert quoted.provider == :schwab

      assert_received {:request, "GET", "/marketdata/v1/quotes", query}
      assert query =~ "symbols=AAPL"
      assert query =~ "indicative=false"
    end

    test "get_top_of_book/2 reads bidPrice/askPrice/quoteTime from the same payload", %{
      body: body
    } do
      assert {:ok, %TopOfBook{} = top} =
               Schwab.get_top_of_book("AAPL",
                 credentials: @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.bid, Decimal.from_float(168.40))
      assert Decimal.equal?(top.ask, Decimal.from_float(168.41))
      assert Decimal.equal?(top.bid_size, Decimal.new(400))
      assert Decimal.equal?(top.ask_size, Decimal.new(400))
      assert top.venue_time == DateTime.from_unix!(1_644_854_683_672, :millisecond)
    end

    test "the same MultiCriteriaSearch example's AAAIX row, a placeholder fund, is refused",
         %{body: body} do
      # The vendor's own example gives this fund `nAV: 0` and zero times. This test used to
      # pin that as a quote of price 0 at venue time 1970-01-01, which is the `||`-on-zero
      # bug `quoted_price/1` and `venue_time/1` now refuse: zero is no price and no time,
      # and with no other price field the quote cannot be built.
      assert {:error, :unexpected_response_shape} =
               Schwab.get_price("AAAIX",
                 credentials: @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # QuoteMutualFund has no bidPrice/askPrice at all in the vendor's own schema — the
      # vendor's own MultiCriteriaSearch example agrees, and get_top_of_book/2 must refuse
      # rather than build a book of four nils that reads as a quiet market.
      assert {:error, :no_top_of_book} =
               Schwab.get_top_of_book("AAAIX",
                 credentials: @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  # ============================================================================
  # Market data — GET /{symbol_id}/quotes (MD:345, .../SingleCriteriaSearch -> $ref
  # SingleSymbolCriteriaSearch). See README.md: the vendor's own doc points this
  # endpoint's 200 example at the price-history example, not a quote shape. Since
  # get_symbol_quote/3 never decodes the body, this pins the pass-through and the
  # single-segment path, and does not invent a second fixture to paper over the mismatch.
  # ============================================================================

  describe "GET /{symbol_id}/quotes — pass-through of whatever shape the venue answers with" do
    test "get_symbol_quote/3 returns the vendor's body unnormalised, from the one-segment path" do
      body = fixture!("market_data/price_history_single_symbol.json")

      capture = fn conn ->
        send(self(), {:request_path, conn.request_path})
        Req.Test.json(conn, body)
      end

      assert {:ok, ^body} =
               Rest.get_symbol_quote("AAPL", @creds, plug: capture, retry_attempts: 0)

      assert_received {:request_path, "/marketdata/v1/AAPL/quotes"}
    end
  end

  # ============================================================================
  # Market data — GET /pricehistory (MD:345/856, components.examples.SingleSymbolCriteriaSearch)
  # ============================================================================

  describe "GET /pricehistory — price_history_single_symbol.json (SingleSymbolCriteriaSearch)" do
    test "get_historical_prices/5 decodes all seven candles, oldest first, as Decimals" do
      body = fixture!("market_data/price_history_single_symbol.json")

      assert {:ok, candles} =
               Schwab.get_historical_prices("AAPL", "1m", [],
                 credentials: @creds,
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert length(candles) == 7
      assert Enum.map(candles, & &1.symbol) == List.duplicate("AAPL", 7)
      assert Enum.map(candles, & &1.timeframe) == List.duplicate("1m", 7)

      first = List.first(candles)
      assert first.opened_at == DateTime.from_unix!(1_639_137_600_000, :millisecond)
      assert Decimal.equal?(first.open, Decimal.from_float(175.01))
      assert Decimal.equal?(first.high, Decimal.from_float(175.15))
      assert Decimal.equal?(first.low, Decimal.from_float(175.01))
      assert Decimal.equal?(first.close, Decimal.from_float(175.04))
      assert Decimal.equal?(first.volume, Decimal.new(10_719))

      last = List.last(candles)
      assert last.opened_at == DateTime.from_unix!(1_640_307_540_000, :millisecond)
      assert Decimal.equal?(last.close, Decimal.from_float(176.32))

      assert_received {:request, "GET", "/marketdata/v1/pricehistory", query}
      assert query =~ "periodType=day"
      assert query =~ "frequencyType=minute"
      assert query =~ "frequency=1"
      assert query =~ "period=10"
      assert query =~ "symbol=AAPL"
    end
  end

  # ============================================================================
  # Market data — GET /markets and GET /markets/{market_id}
  # ============================================================================

  describe "GET /markets — market_hours_all.json (GetMarketHours, MD:759/461)" do
    test "market_status/1 reads equity.EQ.isOpen from the vendor's own nesting" do
      body = fixture!("market_data/market_hours_all.json")

      assert {:ok, :open} =
               Schwab.market_status(credentials: @creds, plug: capturing(body), retry_attempts: 0)

      assert_received {:request, "GET", "/marketdata/v1/markets", query}
      assert query =~ "markets=equity"
    end
  end

  describe "GET /markets/{market_id} — market_hours_single.json (GetMarketHour, MD:723/516)" do
    test "get_market/3 returns the vendor's own map, sessionHours included" do
      body = fixture!("market_data/market_hours_single.json")

      assert {:ok, ^body} =
               Schwab.get_market("equity", @creds, plug: capturing(body), retry_attempts: 0)

      assert %{"equity" => %{"EQ" => %{"isOpen" => true, "sessionHours" => %{}}}} = body

      assert_received {:request, "GET", "/marketdata/v1/markets/equity", _query}
    end
  end

  # ============================================================================
  # Market data — GET /instruments and GET /instruments/{cusip_id}
  # ============================================================================

  describe "GET /instruments — instruments_search.json (GetInstruments, MD:692/576)" do
    test "get_symbols/1 returns sorted canonical symbols from the vendor's instruments array" do
      body = fixture!("market_data/instruments_search.json")

      assert {:ok, ["AAPL", "BAC"]} =
               Schwab.get_symbols(
                 credentials: @creds,
                 query: "AAPL",
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert_received {:request, "GET", "/marketdata/v1/instruments", query}
      assert query =~ "symbol=AAPL"
      assert query =~ "projection=symbol-search"
    end
  end

  describe "GET /instruments/{cusip_id} — instrument_by_cusip.json (GetInstrumentByCusip, MD:713/636)" do
    test "get_instrument/3 returns the vendor's object unnormalised, keyed by CUSIP path" do
      body = fixture!("market_data/instrument_by_cusip.json")

      assert {:ok, ^body} =
               Schwab.get_instrument("037833100", @creds,
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert body["symbol"] == "AAPL"
      assert_received {:request, "GET", "/marketdata/v1/instruments/037833100", _query}
    end
  end

  # ============================================================================
  # Market data — GET /movers/{symbol_id} (MD:825/403, SearchMoversByIndexSymbol)
  # ============================================================================

  describe "GET /movers/{symbol_id} — movers_index.json (SearchMoversByIndexSymbol)" do
    test "get_screener/3 ranks by response position and keeps the venue's own row as metrics" do
      body = fixture!("market_data/movers_index.json")

      assert {:ok, results} =
               Schwab.get_screener("$DJI",
                 credentials: @creds,
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert length(results) == 3
      assert Enum.map(results, & &1.rank) == [1, 2, 3]

      for %ScreenerResult{} = row <- results do
        assert row.symbol == "$DJI"
        assert row.screener == "$DJI"
        assert row.metrics["description"] == "Dow jones"
        assert row.provider == :schwab
      end

      assert_received {:request, "GET", "/marketdata/v1/movers/$DJI", _query}
    end
  end

  # ============================================================================
  # Market data — GET /expirationchain (MD:923/277, GetExpirationChain)
  # ============================================================================

  describe "GET /expirationchain — expiration_chain.json (GetExpirationChain)" do
    test "get_option_expirations/3 reads the vendor's own expirationDate field, sorted" do
      # Every row in the vendor's own worked example spells this field `expirationDate`,
      # not the schema's `expiration` — this is `Rest.expiration_date/1`'s documented
      # fallback clause exercised against real vendor data, not an invented shape.
      body = fixture!("market_data/expiration_chain.json")

      assert {:ok, dates} =
               Schwab.get_option_expirations("AAPL",
                 credentials: @creds,
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert length(dates) == 18
      assert List.first(dates) == ~D[2022-01-07]
      assert List.last(dates) == ~D[2024-01-19]
      assert dates == Enum.sort(dates, Date)

      assert_received {:request, "GET", "/marketdata/v1/expirationchain", query}
      assert query =~ "symbol=AAPL"
    end
  end

  # ============================================================================
  # Market data — GET /chains (schema-derived: no example published, MD:5120/5189/5315)
  # ============================================================================

  describe "GET /chains — option_chain_schema.json (schema-derived OptionChain)" do
    test "get_option_chain/3 builds the expiry/strike grid, both legs, per-side isMini/isNonStandard" do
      body = fixture!("market_data/option_chain_schema.json")

      assert {:ok, %OptionChain{} = chain} =
               Schwab.get_option_chain(
                 "AAPL",
                 credentials: @creds,
                 include_underlying_quote: true,
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert chain.underlying == "AAPL"
      assert Decimal.equal?(chain.underlying_price, Decimal.from_float(227.5))
      assert chain.provider == :schwab

      assert %{~D[2026-03-20] => strikes} = chain.expiries

      {_key, %{call: call, put: put}} =
        Enum.find(strikes, fn {key, _row} -> Decimal.equal?(key, Decimal.new("150.0")) end)

      assert call.right == :call
      assert call.venue_symbol == "AAPL  260320C00150000"
      assert call.mini == false
      assert call.non_standard == false
      assert call.index_option == false
      assert Decimal.equal?(call.multiplier, Decimal.new(100))

      assert put.right == :put
      assert put.venue_symbol == "AAPL  260320P00150000"
      assert put.mini == true
      assert put.non_standard == true

      assert_received {:request, "GET", "/marketdata/v1/chains", query}
      assert query =~ "symbol=AAPL"
      assert query =~ "includeUnderlyingQuote=true"
    end
  end

  # ============================================================================
  # Accounts and trading — GET /accounts/accountNumbers (schema-derived, AT:1119)
  # ============================================================================

  describe "GET /accounts/accountNumbers — account_numbers_schema.json (AccountNumberHash[])" do
    test "get_accounts/2 returns account_number/hash pairs, not the venue's own key names" do
      body = fixture!("accounts_and_trading/account_numbers_schema.json")

      assert {:ok, accounts} =
               Schwab.get_accounts(@creds, plug: capturing(body), retry_attempts: 0)

      assert accounts == [
               %{account_number: "70123456", hash: "9ABCDEF0123456789ABCDEF01234567"},
               %{account_number: "70998877", hash: "1FEDCBA9876543210FEDCBA98765432"}
             ]

      assert_received {:request, "GET", "/trader/v1/accounts/accountNumbers", _query}
    end
  end

  # ============================================================================
  # Accounts and trading — GET /accounts/{accountNumber} (schema-derived, AT:2336 margin,
  # AT:2572 cash)
  # ============================================================================

  describe "GET /accounts/{accountNumber} — account_margin_schema.json (schema-derived MarginAccount)" do
    test "get_balances/2 reads MarginBalance.equity as balance, buyingPower as available" do
      body = fixture!("accounts_and_trading/account_margin_schema.json")

      assert {:ok, [%Balance{} = balance]} =
               Schwab.get_balances(@creds,
                 account_hash: "H",
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert balance.currency == "USD"
      assert Decimal.equal?(balance.balance, Decimal.new(45_825))
      assert Decimal.equal?(balance.available_balance, Decimal.new(30_000))
      assert balance.provider == :schwab

      assert_received {:request, "GET", "/trader/v1/accounts/H", _query}
    end
  end

  describe "GET /accounts/{accountNumber} — account_cash_schema.json (schema-derived CashAccount)" do
    test "get_balances/2 reads CashBalance.totalCash as balance, cashAvailableForTrading as available" do
      body = fixture!("accounts_and_trading/account_cash_schema.json")

      assert {:ok, [%Balance{} = balance]} =
               Schwab.get_balances(@creds,
                 account_hash: "C",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(balance.balance, Decimal.new(5000))
      assert Decimal.equal?(balance.available_balance, Decimal.new(5000))
    end
  end

  # ============================================================================
  # Accounts and trading — GET /accounts (schema-derived, AT:1714, array of Account)
  # ============================================================================

  describe "GET /accounts — account_summaries_schema.json (schema-derived [MarginAccount, CashAccount])" do
    test "get_account_summaries/2 returns the venue's own accounts, unnormalised" do
      body = fixture!("accounts_and_trading/account_summaries_schema.json")

      assert {:ok, [margin, cash]} =
               Schwab.get_account_summaries(@creds, plug: capturing(body), retry_attempts: 0)

      assert margin["securitiesAccount"]["type"] == "MARGIN"
      assert cash["securitiesAccount"]["type"] == "CASH"

      assert_received {:request, "GET", "/trader/v1/accounts", _query}
    end

    test "get_positions/1 flattens both accounts, drops the flat 0/0 position, keeps side and pnl" do
      body = fixture!("accounts_and_trading/account_summaries_schema.json")

      assert {:ok, positions} =
               Schwab.get_positions(credentials: @creds, plug: capturing(body), retry_attempts: 0)

      # The cash account's SPY row (longQuantity: 0, shortQuantity: 0) is a closed position
      # the venue still lists — Position has no way to say "flat", so it is dropped rather
      # than reported as an open position of size nothing.
      assert length(positions) == 2

      assert [%Position{} = aapl, %Position{} = bac] = positions
      assert aapl.symbol == "AAPL"
      assert aapl.side == :long
      assert Decimal.equal?(aapl.quantity, Decimal.new(100))
      assert Decimal.equal?(aapl.average_cost, Decimal.from_float(150.25))
      assert Decimal.equal?(aapl.unrealised_pnl, Decimal.new(725))
      assert aapl.instrument_type == :equity
      assert aapl.provider == :schwab

      assert bac.symbol == "BAC"
      assert bac.side == :short
      assert Decimal.equal?(bac.quantity, Decimal.new(50))
      assert Decimal.equal?(bac.unrealised_pnl, Decimal.new(-75))

      assert_received {:request, "GET", "/trader/v1/accounts", query}
      assert query =~ "fields=positions"
    end
  end

  # ============================================================================
  # Accounts and trading — order reads (schema-derived, AT:1731 Order, AT:2221 OrderLegCollection)
  # ============================================================================

  describe "GET /accounts/{accountNumber}/orders/{orderId} — order_filled_schema.json" do
    test "get_order/3 decodes the single-leg FILLED order into a Types.Order" do
      body = fixture!("accounts_and_trading/order_filled_schema.json")

      assert {:ok, %Order{} = order} =
               Schwab.get_order(@creds, "1000000001",
                 account_hash: "H",
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert order.id == "1000000001"
      assert order.symbol == "AAPL"
      assert order.side == :buy
      assert order.order_type == :limit
      assert order.time_in_force == :day
      assert Decimal.equal?(order.quantity, Decimal.new(10))
      assert Decimal.equal?(order.price, Decimal.from_float(190.25))
      assert order.status == :filled
      assert order.created_at == ~U[2026-01-02 15:04:05Z]
      assert order.provider == :schwab

      assert_received {:request, "GET", "/trader/v1/accounts/H/orders/1000000001", _query}
    end
  end

  describe "GET /orders and GET /accounts/{accountNumber}/orders — orders_window_schema.json" do
    test "get_all_orders/2 requires the venue's window and returns the venue's own (undecoded) rows" do
      # Unlike get_orders/2, get_all_orders/2 does not call Orders.list_from_venue/1 — see
      # its own @spec/@doc: `{:ok, [map()]}`, the venue's own rows, unnormalised.
      body = fixture!("accounts_and_trading/orders_window_schema.json")

      assert {:ok, [filled, working]} =
               Schwab.get_all_orders(@creds,
                 from: ~U[2026-01-01 00:00:00Z],
                 to: ~U[2026-01-03 00:00:00Z],
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert filled["status"] == "FILLED"
      assert working["status"] == "WORKING"
      assert working["filledQuantity"] == 4

      assert_received {:request, "GET", "/trader/v1/orders", query}
      assert query =~ "fromEnteredTime=2026-01-01T00"
      assert query =~ "toEnteredTime=2026-01-03T00"
      assert query =~ ".000Z"
    end

    test "get_orders/2 asks the same window, scoped to one account, and decodes to Types.Order" do
      # Unlike get_all_orders/2, get_orders/2 DOES call Orders.list_from_venue/1 — see its
      # own @impl @doc.
      body = fixture!("accounts_and_trading/orders_window_schema.json")

      assert {:ok, [%Order{} = filled, %Order{} = working]} =
               Schwab.get_orders(@creds,
                 account_hash: "H",
                 from: ~U[2026-01-01 00:00:00Z],
                 to: ~U[2026-01-03 00:00:00Z],
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert filled.status == :filled
      assert working.status == :partially_filled

      assert_received {:request, "GET", "/trader/v1/accounts/H/orders", query}
      assert query =~ "fromEnteredTime="
      assert query =~ "toEnteredTime="
    end
  end

  # ============================================================================
  # Accounts and trading — POST /accounts/{accountNumber}/orders, the vendor's own
  # "Buy Market: Stock" worked example (accounts-and-trading-production.txt:160)
  # ============================================================================

  describe "POST /accounts/{accountNumber}/orders — place_order_request_buy_market_stock.json" do
    test "place_order/3 builds exactly the vendor's documented body and reads the id from Location" do
      expected = fixture!("accounts_and_trading/place_order_request_buy_market_stock.json")

      request = %{symbol: "XYZ", side: :buy, quantity: 15, order_type: :market}

      plug =
        capturing_body(201, %{}, [{"location", "/v1/trader/accounts/H/orders/1000000001"}])

      assert {:ok, "1000000001"} =
               Schwab.place_order(@creds, request,
                 account_hash: "H",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_received {:request, "POST", "/trader/v1/accounts/H/orders", body}
      assert body == expected
    end
  end

  # ============================================================================
  # Accounts and trading — PUT .../orders/{orderId}, the vendor's own "Buy Limit: Single
  # Option" worked example (accounts-and-trading-production.txt:179)
  # ============================================================================

  describe "PUT .../orders/{orderId} — replace_order_request_buy_limit_option.json" do
    test "replace_order/4 builds the vendor's documented body for every field Core can express" do
      expected = fixture!("accounts_and_trading/replace_order_request_buy_limit_option.json")

      request = %{
        symbol: "XYZ   240315C00500000",
        instruction: "BUY_TO_OPEN",
        quantity: 10,
        order_type: :limit,
        price: "6.45"
      }

      plug =
        capturing_body(200, %{}, [{"location", "/v1/trader/accounts/H/orders/1000000002"}])

      assert {:ok, "1000000002"} =
               Schwab.replace_order(@creds, "1000000001", request,
                 account_hash: "H",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_received {:request, "PUT", "/trader/v1/accounts/H/orders/1000000001", body}

      # `complexOrderStrategyType` is part of the vendor's own worked example but has no
      # `Core` request field — nothing a caller of `place_order/3`/`replace_order/4` can
      # set reaches it — so `Orders.build/2` never emits it. That is not a mismatch this
      # package can fix without inventing contract vocabulary Core does not have; every
      # other key the contract CAN express matches the vendor's own example exactly.
      assert Map.drop(expected, ["complexOrderStrategyType"]) == body
      assert body["price"] == "6.45"
      assert body["orderLegCollection"] == expected["orderLegCollection"]
    end
  end

  # ============================================================================
  # Accounts and trading — POST /accounts/{accountNumber}/previewOrder (schema-derived,
  # AT:2037 PreviewOrder, AT:1372 OrderStrategy, AT:1471 OrderLeg)
  # ============================================================================

  describe "POST /accounts/{accountNumber}/previewOrder — preview_order_response_schema.json" do
    test "preview_order/3 sends /previewOrder's own shape and decodes the vendor's own response" do
      response = fixture!("accounts_and_trading/preview_order_response_schema.json")

      request = %{
        symbol: "XYZ   240315C00500000",
        instruction: "BUY_TO_OPEN",
        quantity: 10,
        order_type: :limit,
        price: "6.45"
      }

      plug = capturing_body(200, response)

      assert {:ok, preview} =
               Schwab.preview_order(@creds, request,
                 account_hash: "H",
                 plug: plug,
                 retry_attempts: 0
               )

      # Response side: the vendor's own PreviewOrder/OrderStrategy/OrderLeg shape, decoded
      # as the raw map this endpoint has no Core type for.
      assert preview["orderStrategy"]["orderType"] == "LIMIT"
      assert [leg] = preview["orderStrategy"]["orderLegs"]
      assert leg["finalSymbol"] == "XYZ   240315C00500000"
      assert leg["assetType"] == "OPTION"

      # Request side: PreviewOrder's own shape (orderStrategy/orderLegs, flat assetType
      # and finalSymbol, no nested instrument) — NOT the OrderRequest/orderLegCollection
      # shape place_order/3 sends. This used to send the place_order body verbatim.
      assert_received {:request, "POST", "/trader/v1/accounts/H/previewOrder", sent}
      assert %{"orderStrategy" => strategy} = sent
      refute Map.has_key?(sent, "orderLegCollection")
      assert [sent_leg] = strategy["orderLegs"]
      assert sent_leg["finalSymbol"] == "XYZ   240315C00500000"
      assert sent_leg["assetType"] == "OPTION"
      assert sent_leg["instruction"] == "BUY_TO_OPEN"
      refute Map.has_key?(sent_leg, "instrument")
    end
  end

  # ============================================================================
  # Accounts and trading — GET .../transactions and .../transactions/{id} (schema-derived,
  # AT:3398 Transaction — both endpoints document `type: array`, never a bare object)
  # ============================================================================

  describe "GET .../transactions — transaction_schema.json ([Transaction])" do
    test "get_transactions/2 sends the venue's required window and one scalar type" do
      body = fixture!("accounts_and_trading/transaction_schema.json")

      assert {:ok, [txn]} =
               Schwab.get_transactions(@creds,
                 account_hash: "H",
                 from: ~U[2026-01-01 00:00:00Z],
                 to: ~U[2026-01-03 00:00:00Z],
                 types: "TRADE",
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert txn["type"] == "TRADE"
      assert txn["netAmount"] == -1902.50
      assert [item] = txn["transferItems"]
      assert item["amount"] == 10
      assert item["price"] == 190.25

      assert_received {:request, "GET", "/trader/v1/accounts/H/transactions", query}
      assert query =~ "types=TRADE"
      assert query =~ "startDate="
      assert query =~ "endDate="
    end
  end

  describe "GET .../transactions/{transactionId} — the vendor documents an array here too" do
    test "get_transaction/4 returns the array as sent, not unwrapped to one object" do
      body = fixture!("accounts_and_trading/transaction_schema.json")

      assert {:ok, [_txn]} =
               Schwab.get_transaction(@creds, "H", "900000001",
                 plug: capturing(body),
                 retry_attempts: 0
               )

      assert_received {:request, "GET", "/trader/v1/accounts/H/transactions/900000001", _query}
    end
  end

  # ============================================================================
  # Accounts and trading — GET /userPreference (schema-derived, AT:3579), and the same
  # body proven to bootstrap StreamerInfo.
  # ============================================================================

  describe "GET /userPreference — user_preference_schema.json, also the Streamer's own bootstrap" do
    test "get_user_preference/2 returns the vendor's object unnormalised" do
      body = fixture!("accounts_and_trading/user_preference_schema.json")

      assert {:ok, ^body} =
               Schwab.get_user_preference(@creds, plug: capturing(body), retry_attempts: 0)

      assert_received {:request, "GET", "/trader/v1/userPreference", _query}
    end

    test "the exact same body bootstraps StreamerInfo — one fixture, both entry points" do
      body = fixture!("accounts_and_trading/user_preference_schema.json")

      assert {:ok, info} = StreamerInfo.from_user_preference(body)
      assert info.socket_url == "wss://streamer-api.schwab.com/ws"
      assert info.customer_id == "cust-1"
      assert info.correl_id == "corr-1"
      assert info.channel == "IO"
      assert info.function_id == "APIAPP"
    end
  end

  # ============================================================================
  # Streamer — LEVELONE_EQUITIES, the vendor's own worked "Response Example"
  # (market-data-production.txt:452, SCHW/AAPL/SPY)
  # ============================================================================

  describe "LEVELONE_EQUITIES — level_one_equities_data_frame.json (vendor's own example)" do
    test "every row in the vendor's own example decodes, with no venue_time (fields 34/35 absent)" do
      frame = fixture!("streamer/level_one_equities_data_frame.json")
      observed = ~U[2026-01-01 00:00:00Z]

      # classify/1 returns the top-level "data" array of frame objects (one here); each
      # frame's own "content" is the per-symbol array this package actually decodes.
      assert {:ok, :data, [frame_entry]} = StreamerProtocol.classify(frame)
      assert %{"content" => [_schw, _aapl, _spy] = rows} = frame_entry
      assert {:ok, field_map} = StreamerFields.for_service("LEVELONE_EQUITIES")

      expected = %{
        "SCHW" => {76.08, 76.49, 76.44},
        "AAPL" => {183.75, 183.80, 183.80},
        "SPY" => {512.3, 512.32, 511.29}
      }

      for row <- rows do
        key = row["key"]
        {bid, ask, last} = Map.fetch!(expected, key)
        renamed = StreamerProtocol.rename(row, field_map)

        assert {:ok, %Quote{} = quote_} = StreamerDecode.to_quote(renamed, key, observed)
        assert Decimal.equal?(quote_.price, Decimal.from_float(last))
        assert quote_.venue_time == nil
        assert quote_.observed_at == observed

        assert {:ok, %TopOfBook{} = top} = StreamerDecode.to_top_of_book(renamed, key, observed)
        assert Decimal.equal?(top.bid, Decimal.from_float(bid))
        assert Decimal.equal?(top.ask, Decimal.from_float(ask))
        assert top.venue_time == nil
      end
    end
  end

  describe "LEVELONE_EQUITIES — level_one_equities_venue_time_schema.json (schema-derived, fields 34/35)" do
    test "quote_time/trade_time decode from the authoritative field table, not the shifted generic example" do
      # See README.md: the generic top-of-doc example (market-data-production.txt:112) has
      # its own fields 34/35 shifted one position out of step with the authoritative
      # LEVELONE_EQUITIES field table (market-data-production.txt:663-673) that
      # StreamerFields itself cites. This fixture follows the table, not the
      # contradicting example.
      fields = fixture!("streamer/level_one_equities_venue_time_schema.json")
      observed = ~U[2026-01-01 00:00:00Z]

      assert {:ok, field_map} = StreamerFields.for_service("LEVELONE_EQUITIES")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert {:ok, quote_} = StreamerDecode.to_quote(renamed, "AAPL", observed)
      assert quote_.venue_time == DateTime.from_unix!(1_714_949_592_301, :millisecond)

      assert {:ok, top} = StreamerDecode.to_top_of_book(renamed, "AAPL", observed)
      assert top.venue_time == DateTime.from_unix!(1_714_949_590_000, :millisecond)
    end
  end

  # ============================================================================
  # Streamer — LEVELONE_OPTIONS (schema-derived, market-data-production.txt:811)
  # ============================================================================

  describe "LEVELONE_OPTIONS — level_one_options_frame_schema.json (schema-derived)" do
    test "to_quote/3 reads field 4 (Last Price), and this service carries no venue timestamp" do
      fields = fixture!("streamer/level_one_options_frame_schema.json")
      observed = ~U[2026-01-01 00:00:00Z]

      assert {:ok, field_map} = StreamerFields.for_service("LEVELONE_OPTIONS")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert {:ok, quote_} = StreamerDecode.to_quote(renamed, "AAPL  260320C00150000", observed)
      assert Decimal.equal?(quote_.price, Decimal.from_float(78.75))
      assert quote_.venue_time == nil
      assert renamed[:open_interest] == 500
    end
  end

  # ============================================================================
  # Streamer — LEVELONE_FUTURES (schema-derived, market-data-production.txt:1280) — bid_id
  # (field 6) and ask_id (field 7) are swapped relative to LEVELONE_EQUITIES.
  # ============================================================================

  describe "LEVELONE_FUTURES — level_one_futures_frame_schema.json (schema-derived)" do
    test "to_quote/3 and to_top_of_book/3 read fields 10/11 as quote_time/trade_time" do
      fields = fixture!("streamer/level_one_futures_frame_schema.json")
      observed = ~U[2026-01-01 00:00:00Z]

      assert {:ok, field_map} = StreamerFields.for_service("LEVELONE_FUTURES")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert {:ok, quote_} = StreamerDecode.to_quote(renamed, "/ESZ25", observed)
      assert Decimal.equal?(quote_.price, Decimal.from_float(5900.25))
      assert quote_.venue_time == DateTime.from_unix!(1_714_949_592_301, :millisecond)

      assert {:ok, top} = StreamerDecode.to_top_of_book(renamed, "/ESZ25", observed)
      assert Decimal.equal?(top.bid, Decimal.from_float(5900.25))
      assert Decimal.equal?(top.ask, Decimal.from_float(5900.50))
      assert top.venue_time == DateTime.from_unix!(1_714_949_590_000, :millisecond)
    end
  end

  # ============================================================================
  # Streamer — LEVELONE_FOREX (schema-derived, market-data-production.txt:1930) — names no
  # venue timestamp field at all.
  # ============================================================================

  describe "LEVELONE_FOREX — level_one_forex_frame_schema.json (schema-derived)" do
    test "to_quote/3 reads field 3 (Last Price) and never states a venue_time" do
      fields = fixture!("streamer/level_one_forex_frame_schema.json")
      observed = ~U[2026-01-01 00:00:00Z]

      assert {:ok, field_map} = StreamerFields.for_service("LEVELONE_FOREX")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert {:ok, quote_} = StreamerDecode.to_quote(renamed, "EUR/USD", observed)
      assert Decimal.equal?(quote_.price, Decimal.from_float(1.0822))
      assert quote_.venue_time == nil
    end
  end

  # ============================================================================
  # Streamer — CHART_EQUITY (schema-derived, market-data-production.txt:2274)
  # ============================================================================

  describe "CHART_EQUITY — chart_equity_frame_schema.json (schema-derived)" do
    test "to_candle/3 reads field 7 (Chart Time) as opened_at" do
      fields = fixture!("streamer/chart_equity_frame_schema.json")

      assert {:ok, field_map} = StreamerFields.for_service("CHART_EQUITY")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert {:ok, %Candle{} = candle} = StreamerDecode.to_candle(renamed, "AAPL", "1m")
      assert candle.opened_at == DateTime.from_unix!(1_714_949_580_000, :millisecond)
      assert Decimal.equal?(candle.open, Decimal.from_float(227.10))
      assert Decimal.equal?(candle.high, Decimal.from_float(227.55))
      assert Decimal.equal?(candle.low, Decimal.from_float(226.95))
      assert Decimal.equal?(candle.close, Decimal.from_float(227.40))
      assert Decimal.equal?(candle.volume, Decimal.new(15_234))
    end
  end

  # ============================================================================
  # Streamer — CHART_FUTURES (schema-derived, market-data-production.txt:2389) — field 1 is
  # chart_time and field 2 is open, NOT the CHART_EQUITY numbering.
  # ============================================================================

  describe "CHART_FUTURES — chart_futures_frame_schema.json (schema-derived)" do
    test "to_candle/3 reads field 1, not field 7, as opened_at — the numbering CHART_EQUITY does not share" do
      fields = fixture!("streamer/chart_futures_frame_schema.json")

      assert {:ok, field_map} = StreamerFields.for_service("CHART_FUTURES")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert {:ok, %Candle{} = candle} = StreamerDecode.to_candle(renamed, "/ESZ25", "1m")
      assert candle.opened_at == DateTime.from_unix!(1_714_949_580_000, :millisecond)
      assert Decimal.equal?(candle.open, Decimal.from_float(5899.75))
      assert Decimal.equal?(candle.close, Decimal.from_float(5900.25))
      assert Decimal.equal?(candle.volume, Decimal.new(4210))
    end
  end

  # ============================================================================
  # Streamer — NYSE_BOOK (shared table with NASDAQ_BOOK/OPTIONS_BOOK), schema-derived,
  # market-data-production.txt:2163
  # ============================================================================

  describe "NYSE_BOOK — nyse_book_frame_schema.json (schema-derived, shared BOOK table)" do
    test "to_order_book/2 keeps the venue's own aggregate size, not the sum of market makers" do
      fields = fixture!("streamer/nyse_book_frame_schema.json")

      assert {:ok, field_map} = StreamerFields.for_service("NYSE_BOOK")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert {:ok, book} = StreamerDecode.to_order_book(renamed, "AAPL")
      assert book.venue_time == DateTime.from_unix!(1_714_949_592_301, :millisecond)

      # Best bid first (desc), best ask first (asc).
      assert [{best_bid, best_bid_size}, {_next_bid_price, _next_bid_size}] = book.bids
      assert Decimal.equal?(best_bid, Decimal.from_float(227.40))
      # The venue's own aggregate (550) is kept, not the market makers' sum (300 + 200 = 500).
      assert Decimal.equal?(best_bid_size, Decimal.new(550))

      assert [{best_ask, _best_ask_size}, {_next_ask_price, _next_ask_size}] = book.asks
      assert Decimal.equal?(best_ask, Decimal.from_float(227.45))
    end
  end

  # ============================================================================
  # Streamer — SCREENER_EQUITY (shared table with SCREENER_OPTION), schema-derived,
  # market-data-production.txt:2498. No Core value type yet — field renaming is the whole
  # decode this package does for it (Socket's own comment).
  # ============================================================================

  describe "SCREENER_EQUITY — screener_equity_frame_schema.json (schema-derived)" do
    test "field renaming names symbol/snapshot_time/sort_field/frequency/items" do
      fields = fixture!("streamer/screener_equity_frame_schema.json")

      assert {:ok, field_map} = StreamerFields.for_service("SCREENER_EQUITY")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert renamed[:symbol] == "$DJI_PERCENT_CHANGE_UP_60"
      assert renamed[:sort_field] == "PERCENT_CHANGE_UP"
      assert renamed[:frequency] == 60
      assert [item] = renamed[:items]
      assert item["symbol"] == "$DJI"
      assert item["lastPrice"] == 100.0
    end
  end

  # ============================================================================
  # Streamer — ACCT_ACTIVITY, schema-derived, market-data-production.txt:2626 — keyed on
  # "seq"/"key" for two of its four fields.
  # ============================================================================

  describe "ACCT_ACTIVITY — acct_activity_frame_schema.json (schema-derived)" do
    test "field renaming reads seq/key literally alongside numbered fields 1-3" do
      fields = fixture!("streamer/acct_activity_frame_schema.json")

      assert {:ok, field_map} = StreamerFields.for_service("ACCT_ACTIVITY")
      renamed = StreamerProtocol.rename(fields, field_map)

      assert renamed[:sequence] == 42
      assert renamed[:key] == "Account Activity"
      assert renamed[:account] == "70123456"
      assert renamed[:message_type] == "OrderFill"
      assert renamed[:message_data] == "{}"
    end
  end
end
