defmodule DpExchange.Schwab.FakeFidelityTest do
  @moduledoc """
  The fake refuses what the real path refuses, **in the same order**, and answers with the
  shapes the real decode produces.

  Every refusal compared here is one the real facade makes locally, before any request
  leaves, so each is asserted against the real facade and the fake side by side and neither
  needs a network. A consumer whose tests run against the fake would otherwise see a
  different error from the one production returns for the same mistake.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Rest}

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
  @window [from: ~U[2026-08-01 00:00:00Z], to: ~U[2026-09-01 00:00:00Z]]

  # Around now, where an order the fake just placed was entered. The canned order (entered
  # 2026-01-02) is outside it, and no window of at most a year holds both for ever.
  defp now_window do
    now = DateTime.utc_now()
    [from: DateTime.add(now, -3600, :second), to: DateTime.add(now, 3600, :second)]
  end

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  # Order type and time-in-force are required of every order: nothing is defaulted.
  @buy %{symbol: "AAPL", side: :buy, quantity: 1, order_type: :market, time_in_force: :day}

  describe "the account hash comes before the credential, as in the facade" do
    test "every account endpoint names the missing hash when both are missing" do
      request = @buy

      cases = [
        {:get_balances, [%{}, []]},
        {:get_order, [%{}, "1", []]},
        {:get_orders, [%{}, []]},
        {:get_transactions, [%{}, []]},
        {:preview_order, [%{}, request, []]},
        {:place_order, [%{}, request, []]},
        {:replace_order, [%{}, "1", request, []]},
        {:cancel_order, [%{}, "1", []]}
      ]

      for {function, args} <- cases do
        real = apply(Schwab, function, args)
        assert real == {:error, {:missing_option, :account_hash}}
        assert apply(Fake, function, args) == real
      end
    end

    test "the order's own shape is refused before the account and the credential" do
      no_side = Map.delete(@buy, :side)

      for opts <- [[], [account_hash: "H"]] do
        args = [%{}, no_side, opts]

        assert {:error, {:missing_field, :side}} = apply(Schwab, :preview_order, args)
        assert apply(Fake, :preview_order, args) == apply(Schwab, :preview_order, args)
        assert apply(Fake, :place_order, args) == apply(Schwab, :place_order, args)

        replace_args = [%{}, "1", no_side, opts]
        assert {:error, {:missing_field, :side}} = apply(Fake, :replace_order, replace_args)

        assert apply(Fake, :replace_order, replace_args) ==
                 apply(Schwab, :replace_order, replace_args)
      end
    end

    test "an unusable order id is refused before the request, the account and the credential" do
      for bad <- [nil, "", "  ", 12, :id, " 12"] do
        refused = {:error, {:invalid_order_id, bad}}

        for opts <- [[], [account_hash: "H"]] do
          assert Fake.get_order(%{}, bad, opts) == refused
          assert Fake.cancel_order(%{}, bad, opts) == refused
          assert Fake.replace_order(%{}, bad, %{}, opts) == refused
          assert Schwab.get_order(%{}, bad, opts) == refused
          assert Schwab.cancel_order(%{}, bad, opts) == refused
          assert Schwab.replace_order(%{}, bad, %{}, opts) == refused
        end
      end
    end

    test "the window is refused before the credential, for orders and transactions" do
      assert {:error, {:from_and_to_required, :schwab}} =
               Schwab.get_orders(%{}, account_hash: "H")

      assert Fake.get_orders(%{}, account_hash: "H") ==
               Schwab.get_orders(%{}, account_hash: "H")

      assert Fake.get_transactions(%{}, account_hash: "H") ==
               Schwab.get_transactions(%{}, account_hash: "H")
    end

    test "with everything else right, the credential is the last refusal" do
      assert {:error, {:missing_credentials, :schwab}} =
               Fake.get_balances(%{}, account_hash: "H")

      assert {:error, {:missing_credentials, :schwab}} =
               Fake.cancel_order(%{}, "1", account_hash: "H")
    end
  end

  describe "transactions: the type is validated by the module that sends it" do
    test "a type outside the venue's enum is refused by the fake as by the facade" do
      opts = [account_hash: "H", types: "EVERYTHING"] ++ @window

      assert {:error, {:unknown_transaction_types, ["EVERYTHING"]}} =
               Schwab.get_transactions(@creds, opts)

      assert Fake.get_transactions(@creds, opts) == Schwab.get_transactions(@creds, opts)
    end

    test "a type given as an atom is refused, not raised on" do
      # `types: :TRADE` matched no clause and raised `CaseClauseError` in the caller.
      opts = [account_hash: "H", types: :TRADE] ++ @window

      assert {:error, {:unknown_transaction_types, [:TRADE]}} =
               Schwab.get_transactions(@creds, opts)

      assert Fake.get_transactions(@creds, opts) == Schwab.get_transactions(@creds, opts)
    end

    test "a one-element list of a non-string is a bad type, not 'multiple types'" do
      opts = [account_hash: "H", types: [:TRADE]] ++ @window

      assert {:error, {:unknown_transaction_types, [:TRADE]}} =
               Schwab.get_transactions(@creds, opts)

      assert Fake.get_transactions(@creds, opts) == Schwab.get_transactions(@creds, opts)
    end

    test "an empty list names no type" do
      opts = [account_hash: "H", types: []] ++ @window

      assert {:error, {:types_required, :schwab}} = Schwab.get_transactions(@creds, opts)
      assert Fake.get_transactions(@creds, opts) == Schwab.get_transactions(@creds, opts)
    end

    test "a valid single type is served by the fake" do
      opts = [account_hash: "H", types: ["TRADE"]] ++ @window
      assert {:ok, [%{"type" => "TRADE"}]} = Fake.get_transactions(@creds, opts)
    end
  end

  describe "movers: the universe is judged before the credential" do
    test "an unknown universe is the same refusal with or without a credential" do
      assert {:error, {:unknown_movers_universe, "NOPE"}} = Schwab.get_screener("NOPE", [])
      assert Fake.get_screener("NOPE", []) == Schwab.get_screener("NOPE", [])
    end

    test "a universe that is not a string is refused, not raised on" do
      assert {:error, {:unknown_movers_universe, :nasdaq}} =
               Rest.get_movers(:nasdaq, @creds, retry_attempts: 0)

      assert {:error, {:unknown_market, :equity}} =
               Rest.get_market(:equity, @creds, retry_attempts: 0)
    end

    test "the fake's row carries the symbol in its metrics, as the venue's row does" do
      assert {:ok, [%{metrics: %{"symbol" => "AAPL"}}]} =
               Fake.get_screener("$DJI", credentials: @creds)
    end
  end

  describe "options: an underlying that is not a symbol is refused, not raised on" do
    test "the chain and the expirations answer an error for a non-string underlying" do
      for bad <- [:aapl, nil, ""] do
        assert {:error, {:invalid_underlying, ^bad}} =
                 Rest.get_option_chain(bad, @creds, retry_attempts: 0)

        assert {:error, {:invalid_underlying, ^bad}} =
                 Rest.get_option_expirations(bad, @creds, retry_attempts: 0)
      end
    end

    test "the fake refuses it first, before the credential, as the real path does" do
      assert {:error, {:invalid_underlying, :aapl}} = Fake.get_option_chain(:aapl, [])
      assert {:error, {:invalid_underlying, :aapl}} = Fake.get_option_expirations(:aapl, [])
    end
  end

  describe "history: the range is judged by the module that sends the request" do
    test "an end with no start is refused by the fake as by the facade" do
      range = [end: ~U[2026-06-05 00:00:00Z]]
      opts = [credentials: @creds]

      assert {:error, {:range_start_required, :schwab}} =
               Schwab.get_historical_prices("AAPL", "1d", range, opts)

      assert Fake.get_historical_prices("AAPL", "1d", range, opts) ==
               Schwab.get_historical_prices("AAPL", "1d", range, opts)
    end

    test "a start after its end is refused by the fake as by the facade" do
      range = [start: ~U[2026-06-05 00:00:00Z], end: ~U[2026-06-01 00:00:00Z]]
      opts = [credentials: @creds]

      assert {:error, {:range_start_after_end, :schwab}} =
               Schwab.get_historical_prices("AAPL", "1d", range, opts)

      assert Fake.get_historical_prices("AAPL", "1d", range, opts) ==
               Schwab.get_historical_prices("AAPL", "1d", range, opts)
    end

    test "a bounded window is sized by its own span, not by how long ago it began" do
      # Thirty days back, but a one-day window: the venue is asked for one day of one-minute
      # bars, which it can serve. The fake measured from the start alone and refused it.
      start = DateTime.add(Fake.as_of(), -30, :day)
      range = [start: start, end: DateTime.add(start, 1, :day)]

      assert {:ok, [_first | _rest]} =
               Fake.get_historical_prices("AAPL", "1m", range, credentials: @creds)

      assert :ok = Rest.check_history("1m", range, Fake.as_of())
    end

    test "an open-ended range is still measured back from now" do
      range = [start: DateTime.add(Fake.as_of(), -30, :day)]

      earliest = DateTime.add(Fake.as_of(), -10, :day)
      requested = DateTime.add(Fake.as_of(), -30, :day)
      expected = {:error, {:range_unavailable, "1m", earliest: earliest, requested: requested}}

      assert expected == Rest.check_history("1m", range, Fake.as_of())

      assert expected ==
               Fake.get_historical_prices("AAPL", "1m", range, credentials: @creds)
    end

    test "the bar still forming is withheld unless include_partial: true, as the real path" do
      opts = [credentials: @creds]
      forming = ~U[2026-08-31 00:00:00Z]

      assert {:ok, finished} = Fake.get_historical_prices("AAPL", "1d", [], opts)
      assert length(finished) == 4
      assert Enum.all?(finished, &(DateTime.compare(&1.opened_at, forming) == :lt))

      assert {:ok, all} =
               Fake.get_historical_prices("AAPL", "1d", [], opts ++ [include_partial: true])

      assert length(all) == 5
      assert List.last(all).opened_at == forming
    end

    test "a non-boolean include_partial is refused by the fake as by the real path" do
      opts = [credentials: @creds, include_partial: "yes"]

      assert {:error, {:invalid_option, :include_partial, "yes"}} =
               Fake.get_historical_prices("AAPL", "1d", [], opts)

      assert {:error, {:invalid_option, :include_partial, "yes"}} =
               Schwab.get_historical_prices("AAPL", "1d", [], opts)
    end

    test ":start is inclusive and :end exclusive on opened_at" do
      start = ~U[2026-08-27 00:00:00Z]
      range = [start: start, end: ~U[2026-08-29 00:00:00Z]]

      assert {:ok, bars} = Fake.get_historical_prices("AAPL", "1d", range, credentials: @creds)
      assert Enum.map(bars, & &1.opened_at) == [start, ~U[2026-08-28 00:00:00Z]]
    end
  end

  describe "a credential is judged by the module that signs" do
    @unsignable [%{access_token: ""}, %{access_token: "   "}, %{refresh_token: "r"}, %{}]

    test "a blank or tokenless credential is refused on every account read and write" do
      missing = {:error, {:missing_credentials, :schwab}}
      request = @buy

      for creds <- @unsignable do
        assert Fake.get_accounts(creds) == missing
        assert Fake.get_balances(creds, account_hash: "H") == missing
        assert Fake.get_order(creds, "1", account_hash: "H") == missing
        assert Fake.cancel_order(creds, "1", account_hash: "H") == missing
        assert Fake.place_order(creds, request, account_hash: "H") == missing
        assert Fake.get_positions(credentials: creds) == missing
        assert Fake.get_option_expirations("AAPL", credentials: creds) == missing
        assert Fake.get_screener("$DJI", credentials: creds) == missing
      end
    end

    test "market data refuses the same credentials, after judging its own arguments" do
      missing = {:error, {:missing_credentials, :schwab}}

      for creds <- [%{access_token: ""}, %{refresh_token: "r"}] do
        opts = [credentials: creds]
        assert Fake.get_price("AAPL", opts) == missing
        assert Fake.get_top_of_book("AAPL", opts) == missing
        assert Fake.get_historical_prices("AAPL", "1d", [], opts) == missing
        assert Fake.get_symbols(opts ++ [query: "A"]) == missing
        assert Fake.market_status(opts) == missing

        # What the real facade answers for the same call, locally and before any request.
        assert Schwab.get_price("AAPL", opts) == missing
        assert Schwab.get_symbols(opts ++ [query: "A"]) == missing
        assert Schwab.market_status(opts) == missing
      end
    end

    test "the request's own refusals come before a blank token, in the real order" do
      opts = [credentials: %{access_token: ""}]

      calls = [
        {:get_price, ["BTC-USD", opts]},
        {:get_top_of_book, ["BTC-USD", opts]},
        {:get_historical_prices, ["AAPL", "2h", [], opts]},
        {:get_symbols, [opts]},
        {:market_status, [opts ++ [market: "crypto"]]}
      ]

      for {function, args} <- calls do
        real = apply(Schwab, function, args)
        refute real == {:error, {:missing_credentials, :schwab}}
        assert apply(Fake, function, args) == real
      end
    end

    test "a credential that is not a map is refused before the symbol is judged" do
      missing = {:error, {:missing_credentials, :schwab}}

      for opts <- [[], [credentials: nil], [credentials: "token"]] do
        assert Schwab.get_price("BTC-USD", opts) == missing
        assert Fake.get_price("BTC-USD", opts) == missing
      end
    end
  end

  describe "positions: the account is named by number, as Rest names it" do
    test "a number the credential has no account for is the venue-shaped refusal" do
      opts = [credentials: @creds, account_number: "999"]
      assert Fake.get_positions(opts) == {:refused, {:account_not_found, "999"}}
    end

    test "the account the fake holds, or no number, is served" do
      assert {:ok, [_position]} = Fake.get_positions(credentials: @creds)

      assert {:ok, [_position]} =
               Fake.get_positions(credentials: @creds, account_number: "123456789")

      assert {:ok, [%{account_number: "123456789"}]} = Fake.get_accounts(@creds)
    end

    test "the credential is judged before the number, as the read comes first" do
      assert Fake.get_positions(account_number: "999") ==
               {:error, {:missing_credentials, :schwab}}
    end
  end

  describe "options: the chain's dates are judged before the credential" do
    test "an unreadable date is refused by the fake as by the facade" do
      unreadable = [from_date: "soon", to_date: 20_260_101, from_date: ~U[2026-01-01 00:00:00Z]]

      for {key, value} <- unreadable do
        opts = [{key, value}]
        real = Schwab.get_option_chain("AAPL", opts)

        assert {:error, {:invalid_date, ^key, ^value}} = real
        assert Fake.get_option_chain("AAPL", opts) == real
      end
    end

    test "a readable date passes, and then the credential is the refusal" do
      opts = [from_date: ~D[2026-03-01], to_date: "2026-04-01"]

      assert Fake.get_option_chain("AAPL", opts) == {:error, {:missing_credentials, :schwab}}
      assert {:ok, _chain} = Fake.get_option_chain("AAPL", opts ++ [credentials: @creds])
    end
  end

  describe "orders: maxResults narrows the page as the venue's does" do
    test "a positive integer takes that many, in id order" do
      opts = [account_hash: "H"]
      request = @buy
      assert {:ok, first} = Fake.place_order(@creds, request, opts)
      assert {:ok, second} = Fake.place_order(@creds, request, opts)

      window = opts ++ now_window()
      assert {:ok, [listed_first, listed_second]} = Fake.get_orders(@creds, window)
      assert [listed_first.id, listed_second.id] == [first.id, second.id]

      assert {:ok, [only]} = Fake.get_orders(@creds, window ++ [max_results: 1])
      assert only.id == first.id
      assert {:ok, [_one, _two]} = Fake.get_orders(@creds, window ++ [max_results: 10])
    end
  end

  describe "the feed's own reads: wanted, status, update_credentials" do
    test "wanted holds every valid symbol asked for, coverage only those the fake delivers" do
      :ok = Fake.subscribe(["aapl", "TSLA"], to: self())

      assert Enum.sort(Fake.wanted()) == ["AAPL", "TSLA"]
      assert Map.keys(Fake.coverage()) == ["AAPL"]
      assert %{route: :stream, symbols: 2, covered: 1, delivering: true} = Fake.status()

      :ok = Fake.unsubscribe(["AAPL"])
      assert Fake.wanted() == ["TSLA"]
      assert %{delivering: false, covered: 0} = Fake.status()

      :ok = Fake.update_symbols(["MSFT"], to: self())
      assert Fake.wanted() == ["MSFT"]
    end

    test "a refused symbol set changes nothing that wanted reports" do
      :ok = Fake.subscribe(["AAPL"], to: self())
      assert {:error, {:invalid_symbols, ["BTC-USD"]}} = Fake.subscribe(["BTC-USD"])
      assert Fake.wanted() == ["AAPL"]
    end

    test "update_credentials answers as the facade does" do
      assert Fake.update_credentials(@creds) == :ok
      assert Fake.update_credentials(nil) == {:error, {:invalid_credentials, :schwab}}
      assert Schwab.update_credentials(nil) == {:error, {:invalid_credentials, :schwab}}
    end

    test "the static lists and predicates are the facade's own" do
      assert Fake.movers_universes() == Schwab.movers_universes()
      assert Fake.markets() == Schwab.markets()
      assert Fake.transaction_types() == Schwab.transaction_types()
      assert Fake.equity_instructions() == Schwab.equity_instructions()
      assert Fake.option_instructions() == Schwab.option_instructions()
      assert Fake.credential_failure?(401) == Schwab.credential_failure?(401)
      assert Fake.needs_refresh?(%{access_token: "t"}) == false
    end
  end

  describe "the fake's values are the shapes the real decode produces" do
    test "available balance is part of the total, never more than it" do
      assert {:ok, [balance]} = Fake.get_balances(@creds, account_hash: "H")
      assert Decimal.compare(balance.available_balance, balance.balance) != :gt
    end

    test "a short position is unsigned and states no realised P/L" do
      assert {:ok, [position]} = Fake.get_positions(credentials: @creds)
      assert position.side == :short
      refute Decimal.negative?(position.notional_value)
      assert position.realised_pnl == nil
    end
  end

  describe "issued ids are the venue's own format, and round-trip" do
    test "get_accounts -> get_balances takes the hash the fake issued, the spec's own value" do
      assert {:ok, [%{hash: hash}]} = Fake.get_accounts(@creds)
      # The spec fixture's `hashValue`. The spec states no length, so none is asserted.
      assert hash == "9ABCDEF0123456789ABCDEF01234567"
      assert hash =~ ~r/\A[0-9A-F]+\z/

      assert {:ok, [_balance]} = Fake.get_balances(@creds, account_hash: hash)
    end

    test "place -> get -> replace -> cancel -> list run on numeric order ids" do
      request = @buy
      opts = [account_hash: "H"]

      # `orderId` is an int64 on the wire; `Orders.from_venue/1` returns its decimal string.
      assert {:ok, placed} = Fake.place_order(@creds, request, opts)
      assert placed.id =~ ~r/\A\d+\z/

      assert {:ok, read} = Fake.get_order(@creds, placed.id, opts)
      assert read.id == placed.id

      assert {:ok, replaced} = Fake.replace_order(@creds, placed.id, request, opts)
      assert replaced.id =~ ~r/\A\d+\z/
      refute replaced.id == placed.id

      # The replaced order is no longer working, so the venue refuses to cancel it.
      assert {:refused, {:venue_error, 400}} = Fake.cancel_order(@creds, placed.id, opts)
      assert {:ok, :cancelled} = Fake.cancel_order(@creds, replaced.id, opts)

      assert {:ok, [first, second]} = Fake.get_orders(@creds, opts ++ now_window())
      assert first.id =~ ~r/\A\d+\z/
      assert second.id == replaced.id
    end
  end

  describe "an order the fake placed is the order it reads back and cancels" do
    test "the symbol, instruction and working state come back, not a filled AAPL buy" do
      # A text side is normalised: the fake answers `:sell`, not the caller's string.
      request = Map.merge(@buy, %{symbol: "MSFT", side: "SELL", quantity: 5})
      opts = [account_hash: "H"]

      assert {:ok, placed} = Fake.place_order(@creds, request, opts)
      assert placed.symbol == "MSFT"
      assert placed.side == :sell
      assert placed.status == :open
      assert Decimal.equal?(placed.quantity, Decimal.new(5))

      assert {:ok, read} = Fake.get_order(@creds, placed.id, opts)
      assert read.symbol == "MSFT"
      assert read.side == :sell
      assert read.status == :open

      assert {:ok, [listed]} = Fake.get_orders(@creds, opts ++ now_window())
      assert listed.id == placed.id
      assert listed.symbol == "MSFT"

      working = opts ++ now_window() ++ [status: "WORKING"]
      assert {:ok, [only_working]} = Fake.get_orders(@creds, working)
      assert only_working.id == placed.id
    end

    test "cancel marks the order cancelled, and a second cancel is refused" do
      opts = [account_hash: "H"]

      assert {:ok, placed} = Fake.place_order(@creds, @buy, opts)

      assert {:ok, :cancelled} = Fake.cancel_order(@creds, placed.id, opts)
      assert {:ok, %{status: :cancelled}} = Fake.get_order(@creds, placed.id, opts)
      assert {:refused, {:venue_error, 400}} = Fake.cancel_order(@creds, placed.id, opts)
    end

    test "an id the fake never issued is {:refused, :not_found} on every call" do
      opts = [account_hash: "H"]
      request = @buy

      assert {:refused, :not_found} = Fake.get_order(@creds, "42", opts)
      assert {:refused, :not_found} = Fake.cancel_order(@creds, "42", opts)
      assert {:refused, :not_found} = Fake.replace_order(@creds, "42", request, opts)
    end

    test "a replacement id reads back and cancels, as the round trip requires" do
      opts = [account_hash: "H"]
      request = @buy

      assert {:ok, placed} = Fake.place_order(@creds, request, opts)
      assert {:ok, replaced} = Fake.replace_order(@creds, placed.id, request, opts)
      assert {:ok, %{id: id}} = Fake.get_order(@creds, replaced.id, opts)
      assert id == replaced.id
      assert {:ok, :cancelled} = Fake.cancel_order(@creds, replaced.id, opts)
    end
  end

  describe "get_orders/2 honours the entered-time window" do
    @request @buy

    test "the canned order is listed only when its entry date is inside the window" do
      opts = [account_hash: "H"]

      inside = [from: ~U[2026-01-02 00:00:00Z], to: ~U[2026-01-03 00:00:00Z]]
      assert {:ok, [%{id: "1005439821"}]} = Fake.get_orders(@creds, opts ++ inside)

      before = [from: ~U[2026-02-01 00:00:00Z], to: ~U[2026-03-01 00:00:00Z]]
      assert {:ok, []} = Fake.get_orders(@creds, opts ++ before)
    end

    test "a placed order is listed in a window around now and not in one in the past" do
      opts = [account_hash: "H"]
      assert {:ok, placed} = Fake.place_order(@creds, @request, opts)

      now = DateTime.utc_now()
      around = [from: DateTime.add(now, -3600, :second), to: DateTime.add(now, 3600, :second)]
      assert {:ok, [listed]} = Fake.get_orders(@creds, opts ++ around)
      assert listed.id == placed.id

      past = [from: ~U[2026-02-01 00:00:00Z], to: ~U[2026-03-01 00:00:00Z]]
      assert {:ok, []} = Fake.get_orders(@creds, opts ++ past)
    end

    test "the venue's string form is parsed" do
      opts = [account_hash: "H"]
      text = [from: "2026-01-02T00:00:00.000Z", to: "2026-01-03T00:00:00.000Z"]
      assert {:ok, [%{id: "1005439821"}]} = Fake.get_orders(@creds, opts ++ text)
    end

    test "the fake refuses exactly what Rest refuses: unreadable, reversed and over a year" do
      opts = [account_hash: "H"]

      windows = [
        {[from: "yesterday", to: "today"], {:order_window_invalid, :schwab}},
        {[from: 1, to: 2], {:order_window_invalid, :schwab}},
        {[from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-02-01 00:00:00Z]],
         {:order_window_reversed, :schwab}},
        {[from: ~U[2025-01-01 00:00:00Z], to: ~U[2026-01-02 00:00:00Z]],
         {:order_window_too_long, :schwab}}
      ]

      for {window, reason} <- windows do
        assert Fake.get_orders(@creds, opts ++ window) == {:error, reason}
        assert Rest.check_order_window(window) == {:error, reason}
      end

      exactly_a_year = [from: ~U[2025-01-01 00:00:00Z], to: ~U[2026-01-01 00:00:00Z]]
      assert Rest.check_order_window(exactly_a_year) == :ok
    end

    test "the fake refuses a status outside the venue's enum, as Rest does" do
      window = [from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-03 00:00:00Z]]

      for status <- [:working, "working", "SOMETHING_ELSE", 1] do
        reason = {:error, {:invalid_order_status, status}}
        assert Fake.get_orders(@creds, [account_hash: "H", status: status] ++ window) == reason
        assert Rest.check_order_window([status: status] ++ window) == reason
      end
    end

    test "an integer order id is refused, on the fake and the facade alike" do
      opts = [account_hash: "H"]
      refused = {:error, {:invalid_order_id, 1_005_439_821}}

      assert Fake.get_order(@creds, 1_005_439_821, opts) == refused
      assert Schwab.get_order(@creds, 1_005_439_821, opts) == refused
    end

    test "the fake refuses what Rest refuses for a transactions window" do
      opts = [account_hash: "H", types: ["TRADE"]]

      windows = [
        {[from: ~U[2026-03-01 00:00:00Z], to: ~U[2026-02-01 00:00:00Z]],
         {:transaction_window_reversed, :schwab}},
        {[from: ~U[2025-01-01 00:00:00Z], to: ~U[2026-01-02 00:00:00Z]],
         {:transaction_window_too_long, :schwab}},
        {[from: "yesterday", to: "today"], {:transaction_window_invalid, :schwab}}
      ]

      for {window, reason} <- windows do
        assert Fake.get_transactions(@creds, opts ++ window) == {:error, reason}
        assert Rest.check_transactions(opts ++ window) == {:error, reason}
      end
    end
  end

  describe "the real endpoints these tests lean on" do
    test "a single-symbol quote that is not an object is refused" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_symbol_quote("AAPL", @creds,
                 plug: responding([%{"quote" => %{}}]),
                 retry_attempts: 0
               )
    end

    test "contract_type reaches the venue, and so does the camelCase spelling" do
      for key <- [:contract_type, :contractType] do
        opts = [{key, "CALL"}, symbol: "AAPL", plug: capturing(%{}, self()), retry_attempts: 0]

        assert {:ok, _body} = Rest.get_chains(@creds, opts)

        assert_receive {:request, "/marketdata/v1/chains", query}
        assert URI.decode_query(query)["contractType"] == "CALL"
      end
    end

    test "no contract type is sent when none is given" do
      assert {:ok, _body} =
               Rest.get_chains(@creds,
                 symbol: "AAPL",
                 plug: capturing(%{}, self()),
                 retry_attempts: 0
               )

      assert_receive {:request, "/marketdata/v1/chains", query}
      refute Map.has_key?(URI.decode_query(query), "contractType")
    end
  end
end
