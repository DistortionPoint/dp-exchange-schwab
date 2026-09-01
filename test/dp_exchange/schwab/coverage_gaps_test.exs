defmodule DpExchange.Schwab.CoverageGapsTest do
  @moduledoc """
  The eleven REST endpoints this package did not reach, and what each one refuses.

  **Three of the four closed boxes were closed on a claim about the package, not the venue**
  — option chains, expirations and movers were all published and unimplemented, which the
  declaration said plainly and this now fixes.

  The assertions worth the most are the required parameters this package refuses to default:
  `/orders` needs a time window and `/transactions` needs a window **and a type list with no
  "all" in it**. A window or a type set chosen here returns a real answer over the wrong
  period or missing whichever kinds it left out, and an empty result reads as "nothing
  happened".
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.{Config, Types}
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

  defp responding(body), do: fn conn -> Req.Test.json(conn, body) end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  describe "the market-data reads that were missing" do
    test "a single-symbol quote uses a path segment, not a query list" do
      me = self()

      assert {:ok, _quote} =
               Rest.get_symbol_quote("AAPL", @creds,
                 fields: "quote,reference",
                 plug: capturing(%{"AAPL" => %{}}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert String.ends_with?(path, "/AAPL/quotes")
      assert query =~ "fields=quote%2Creference"
    end

    test "no fields are sent when none were asked for, which is the venue's 'all'" do
      me = self()

      assert {:ok, _quote} =
               Rest.get_symbol_quote("AAPL", @creds,
                 plug: capturing(%{"AAPL" => %{}}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, ""}
    end

    test "a chain needs a symbol and refuses without one" do
      assert {:error, {:symbol_required, :schwab}} = Rest.get_chains(@creds, [])
    end

    test "the model inputs are sent only when the caller supplied them" do
      # volatility, underlyingPrice, interestRate and daysToExpiration are what Schwab
      # prices an analytical chain with. Supplying them here would price a chain against
      # numbers this package invented.
      me = self()

      assert {:ok, _chain} =
               Rest.get_chains(@creds,
                 symbol: "AAPL",
                 plug: capturing(%{"symbol" => "AAPL"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert String.ends_with?(path, "/chains")
      assert query == "symbol=AAPL"
      refute query =~ "volatility"
      refute query =~ "interestRate"
    end

    test "a date and a decimal reach the venue in its own formats" do
      me = self()

      assert {:ok, _chain} =
               Rest.get_chains(@creds,
                 symbol: "AAPL",
                 from_date: ~D[2026-03-01],
                 strike: Decimal.new("200.5"),
                 strategy: "ANALYTICAL",
                 volatility: 29.0,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}
      assert query =~ "fromDate=2026-03-01"
      assert query =~ "strike=200.5"
      assert query =~ "strategy=ANALYTICAL"
      assert query =~ "volatility=29.0"
    end

    test "a mover universe outside the venue's enum is refused before the request" do
      # A ticker sent here is not a smaller mover list, it is a 404.
      assert {:error, {:unknown_movers_universe, "AAPL"}} =
               Rest.get_movers("AAPL", @creds, [])

      assert "$DJI" in Rest.movers_universes()
      assert "OPTION_PUT" in Rest.movers_universes()
    end

    test "a mover request sends only the filters that were given" do
      me = self()

      assert {:ok, _movers} =
               Rest.get_movers("$SPX", @creds,
                 sort: "VOLUME",
                 frequency: 60,
                 plug: capturing(%{"screeners" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert path =~ "/movers/"
      assert query =~ "sort=VOLUME"
      assert query =~ "frequency=60"
    end

    test "a market outside the venue's five is refused" do
      assert {:error, {:unknown_market, "crypto"}} = Rest.get_market("crypto", @creds, [])
      assert Rest.markets() == ~w(equity option bond future forex)
    end

    test "a market's hours can be asked for another day" do
      # "Is the bond market open on the 4th" is not answerable from today's status.
      me = self()

      assert {:ok, _hours} =
               Rest.get_market("bond", @creds,
                 date: ~D[2026-07-04],
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert String.ends_with?(path, "/markets/bond")
      assert query == "date=2026-07-04"
    end

    test "an instrument is fetched by CUSIP in the path" do
      me = self()

      assert {:ok, _instrument} =
               Rest.get_instrument("037833100", @creds,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, ""}
      assert String.ends_with?(path, "/instruments/037833100")
    end
  end

  describe "get_option_chain/3 rebuilds the grid" do
    defp chain_body do
      %{
        "symbol" => "AAPL",
        "underlyingPrice" => 201.5,
        "callExpDateMap" => %{
          "2026-03-20:15" => %{
            "200.0" => [
              %{
                "symbol" => "AAPL  260320C00200000",
                "multiplier" => 100.0,
                "settlementType" => "P",
                "nonStandard" => false,
                "lastTradingDay" => 1_774_060_800_000
              }
            ]
          }
        },
        "putExpDateMap" => %{
          "2026-03-20:15" => %{
            "200.0" => [%{"symbol" => "AAPL  260320P00200000", "multiplier" => 100.0}]
          },
          "2026-06-19:106" => %{
            "220.0" => [%{"symbol" => "AAPL  260619P00220000"}]
          }
        }
      }
    end

    test "the call and put at one strike land on the same row" do
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @creds,
                 plug: responding(chain_body()),
                 retry_attempts: 0
               )

      assert %Types.OptionChain{} = chain
      row = chain.expiries[~D[2026-03-20]][Decimal.new("200.0")]
      assert row.call.right == :call
      assert row.put.right == :put
      assert row.call.venue_symbol == "AAPL  260320C00200000"
    end

    test "a strike with only a put keeps a nil call" do
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @creds,
                 plug: responding(chain_body()),
                 retry_attempts: 0
               )

      row = chain.expiries[~D[2026-06-19]][Decimal.new("220.0")]
      assert row.put
      assert row.call == nil
    end

    test "the expiry key's days-to-expiration is dropped, because it is a countdown" do
      # `2026-03-20:15` — the 15 is days from today and would be stale as a key.
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @creds,
                 plug: responding(chain_body()),
                 retry_attempts: 0
               )

      assert Types.OptionChain.expiry_dates(chain) == [~D[2026-03-20], ~D[2026-06-19]]
    end

    test "the underlying price is carried when the venue sent it" do
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @creds,
                 plug: responding(chain_body()),
                 retry_attempts: 0
               )

      assert Decimal.equal?(chain.underlying_price, Decimal.from_float(201.5))
    end

    test "and is nil when it did not" do
      # nil means it was not in the response, not that the underlying has no price.
      body = Map.delete(chain_body(), "underlyingPrice")

      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @creds, plug: responding(body), retry_attempts: 0)

      assert chain.underlying_price == nil
    end

    test "an expiry key this package cannot read is refused, not dropped" do
      body = %{"callExpDateMap" => %{"not-a-date" => %{"200.0" => [%{}]}}}

      assert {:error, {:unreadable_chain_expiry, "not-a-date"}} =
               Rest.get_option_chain("AAPL", @creds, plug: responding(body), retry_attempts: 0)
    end

    test "an unreadable strike is refused too" do
      body = %{"callExpDateMap" => %{"2026-03-20:15" => %{"at-the-money" => [%{}]}}}

      assert {:error, {:unreadable_chain_strike, "at-the-money"}} =
               Rest.get_option_chain("AAPL", @creds, plug: responding(body), retry_attempts: 0)
    end

    test "a chain with neither side is an empty grid, not an error" do
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @creds,
                 plug: responding(%{"symbol" => "AAPL"}),
                 retry_attempts: 0
               )

      assert chain.expiries == %{}
    end

    test "the last trading day is epoch milliseconds on a row, unlike the expiry key" do
      assert {:ok, chain} =
               Rest.get_option_chain("AAPL", @creds,
                 plug: responding(chain_body()),
                 retry_attempts: 0
               )

      call = chain.expiries[~D[2026-03-20]][Decimal.new("200.0")].call
      assert call.last_trading_day == ~D[2026-03-21]
    end
  end

  describe "get_option_expirations/3 and get_screener/3" do
    test "the expirations come back sorted and deduplicated" do
      body = %{
        "expirationList" => [
          %{"expirationDate" => "2026-06-19"},
          %{"expirationDate" => "2026-03-20"},
          %{"expirationDate" => "2026-03-20"}
        ]
      }

      assert {:ok, dates} =
               Rest.get_option_expirations("AAPL", @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert dates == [~D[2026-03-20], ~D[2026-06-19]]
    end

    test "a date the venue sent that cannot be parsed is dropped rather than refused" do
      # An expiration chain has no strikes hanging off each date, so a missing entry is a
      # missing date and not a hole in a grid.
      body = %{
        "expirationList" => [%{"expirationDate" => "soon"}, %{"expirationDate" => "2026-03-20"}]
      }

      assert {:ok, [~D[2026-03-20]]} =
               Rest.get_option_expirations("AAPL", @creds,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a screener's rank is the venue's returned order" do
      body = %{
        "screeners" => [
          %{"symbol" => "AAPL", "netPercentChange" => 0.01},
          %{"symbol" => "TSLA", "netPercentChange" => 0.09}
        ]
      }

      assert {:ok, [first, second]} =
               Rest.get_screener("$SPX", @creds, plug: responding(body), retry_attempts: 0)

      # TSLA moved more and is still second: re-ranking would answer a different question.
      assert first.symbol == "AAPL"
      assert first.rank == 1
      assert second.rank == 2
      assert second.metrics["netPercentChange"] == 0.09
    end

    test "an unknown universe refuses through the screener too" do
      assert {:error, {:unknown_movers_universe, "AAPL"}} =
               Rest.get_screener("AAPL", @creds, [])
    end
  end

  describe "the account reads that were missing" do
    test "positions are asked for explicitly, because the venue omits them otherwise" do
      me = self()

      assert {:ok, []} =
               Rest.get_positions(@creds, plug: capturing([], me), retry_attempts: 0)

      assert_receive {:request, path, query}
      assert String.ends_with?(path, "/accounts")
      assert query == "fields=positions"
    end

    test "long and short are separate quantities, not one signed number" do
      body = [
        %{
          "securitiesAccount" => %{
            "positions" => [
              %{
                "instrument" => %{"symbol" => "AAPL", "assetType" => "EQUITY"},
                "longQuantity" => 100.0,
                "shortQuantity" => 0.0,
                "averagePrice" => 180.25,
                "marketValue" => 20_150.0
              },
              %{
                "instrument" => %{"symbol" => "TSLA", "assetType" => "EQUITY"},
                "longQuantity" => 0.0,
                "shortQuantity" => 50.0,
                "averagePrice" => 240.0,
                "marketValue" => -12_000.0
              }
            ]
          }
        }
      ]

      assert {:ok, [long, short]} =
               Rest.get_positions(@creds, plug: responding(body), retry_attempts: 0)

      assert long.side == :long
      assert Decimal.equal?(long.quantity, Decimal.from_float(100.0))
      assert short.side == :short
      assert Decimal.equal?(short.quantity, Decimal.from_float(50.0))
      # Both are positive sizes; direction is in :side.
      refute Decimal.negative?(short.quantity)
    end

    test "a row with both quantities zero is skipped" do
      # A closed position the venue still lists is not an open position of size nothing.
      body = [
        %{
          "securitiesAccount" => %{
            "positions" => [
              %{
                "instrument" => %{"symbol" => "AAPL"},
                "longQuantity" => 0.0,
                "shortQuantity" => 0.0
              }
            ]
          }
        }
      ]

      assert {:ok, []} = Rest.get_positions(@creds, plug: responding(body), retry_attempts: 0)
    end

    test "an account with no positions block yields none rather than raising" do
      body = [%{"securitiesAccount" => %{"accountNumber" => "1"}}]
      assert {:ok, []} = Rest.get_positions(@creds, plug: responding(body), retry_attempts: 0)
    end

    test "the account summary asks for nothing extra unless told to" do
      me = self()

      assert {:ok, []} =
               Rest.get_account_summaries(@creds, plug: capturing([], me), retry_attempts: 0)

      assert_receive {:request, _path, ""}
    end

    test "orders across accounts need both ends of the window" do
      # A window this package chose returns a real list over a period the caller did not ask
      # about, and an empty one reads as "no orders".
      assert {:error, {:from_and_to_required, :schwab}} =
               Rest.get_all_orders(@creds, from: ~U[2026-08-01 00:00:00Z])
    end

    test "a DateTime window reaches the venue in its documented format" do
      me = self()

      assert {:ok, []} =
               Rest.get_all_orders(@creds,
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z],
                 status: "WORKING",
                 max_results: 50,
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert String.ends_with?(path, "/orders")
      assert query =~ "fromEnteredTime=2026-08-01T00%3A00%3A00.000Z"
      assert query =~ "status=WORKING"
      assert query =~ "maxResults=50"
    end

    test "a caller's own string is passed through unreformatted" do
      me = self()

      assert {:ok, []} =
               Rest.get_all_orders(@creds,
                 from: "2026-08-01T00:00:00.000Z",
                 to: "2026-09-01T00:00:00.000Z",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}
      assert query =~ "fromEnteredTime=2026-08-01T00%3A00%3A00.000Z"
    end
  end

  describe "transactions — three required parameters and no 'all'" do
    test "the window is required" do
      assert {:error, {:from_and_to_required, :schwab}} =
               Rest.get_transactions(@creds, "hash-1", types: ["TRADE"])
    end

    test "the types are required, because the venue's enum has no everything" do
      assert {:error, {:types_required, :schwab}} =
               Rest.get_transactions(@creds, "hash-1",
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z]
               )

      assert length(Rest.transaction_types()) == 15
      refute "ALL" in Rest.transaction_types()
    end

    test "a type outside the enum is named back rather than sent" do
      assert {:error, {:unknown_transaction_types, ["EVERYTHING"]}} =
               Rest.get_transactions(@creds, "hash-1",
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z],
                 types: ["TRADE", "EVERYTHING"]
               )
    end

    test "a single type is accepted as a bare string" do
      me = self()

      assert {:ok, []} =
               Rest.get_transactions(@creds, "hash-1",
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z],
                 types: "TRADE",
                 symbol: "AAPL",
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, query}
      assert String.ends_with?(path, "/accounts/hash-1/transactions")
      assert query =~ "types=TRADE"
      assert query =~ "symbol=AAPL"
    end

    test "several types are joined for the venue" do
      me = self()

      assert {:ok, []} =
               Rest.get_transactions(@creds, "hash-1",
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z],
                 types: ["TRADE", "DIVIDEND_OR_INTEREST"],
                 plug: capturing([], me),
                 retry_attempts: 0
               )

      assert_receive {:request, _path, query}
      assert query =~ "types=TRADE%2CDIVIDEND_OR_INTEREST"
    end

    test "one transaction is fetched by id" do
      me = self()

      assert {:ok, _transaction} =
               Rest.get_transaction(@creds, "hash-1", 12_345,
                 plug: capturing(%{"activityId" => 12_345}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, ""}
      assert String.ends_with?(path, "/accounts/hash-1/transactions/12345")
    end

    test "user preferences take no parameters and are the streamer's bootstrap" do
      me = self()

      assert {:ok, _prefs} =
               Rest.get_user_preference(@creds,
                 plug: capturing(%{"streamerInfo" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, path, ""}
      assert String.ends_with?(path, "/userPreference")
    end
  end

  describe "the fake and the facade" do
    test "the fake's chain has a one-sided strike and no underlying price" do
      assert {:ok, chain} = Fake.get_option_chain("AAPL")
      assert chain.underlying_price == nil
      assert chain.expiries[~D[2026-06-19]][Decimal.new("220")].put == nil
    end

    test "the fake's position is a short with a positive size and no liquidation price" do
      assert {:ok, [position]} = Fake.get_positions()
      assert position.side == :short
      refute Decimal.negative?(position.quantity)
      assert position.liquidation_price == nil
    end

    test "the fake refuses the same three missing parameters, in the same order" do
      assert {:error, {:account_hash_required, :schwab}} = Fake.get_transactions(%{})

      assert {:error, {:from_and_to_required, :schwab}} =
               Fake.get_transactions(%{}, account_hash: "h")

      assert {:error, {:types_required, :schwab}} =
               Fake.get_transactions(%{},
                 account_hash: "h",
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z]
               )

      assert {:ok, [_row]} =
               Fake.get_transactions(%{},
                 account_hash: "h",
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z],
                 types: ["TRADE"]
               )
    end

    test "the fake's screener refuses an unknown universe" do
      assert {:error, {:unknown_movers_universe, "AAPL"}} = Fake.get_screener("AAPL")
      assert {:ok, [%{rank: 1}]} = Fake.get_screener("$DJI")
    end

    test "the facade reaches the new surface" do
      base = [credentials: @creds, retry_attempts: 0]

      assert {:ok, _chain} =
               DpExchange.Schwab.get_option_chain(
                 "AAPL",
                 base ++ [plug: responding(chain_body())]
               )

      assert {:ok, _dates} =
               DpExchange.Schwab.get_option_expirations(
                 "AAPL",
                 base ++ [plug: responding(%{"expirationList" => []})]
               )

      assert {:ok, _movers} =
               DpExchange.Schwab.get_screener(
                 "$DJI",
                 base ++ [plug: responding(%{"screeners" => []})]
               )

      assert {:ok, []} = DpExchange.Schwab.get_positions(base ++ [plug: responding([])])

      assert {:error, {:account_hash_required, :schwab}} =
               DpExchange.Schwab.get_transactions(@creds, [])

      assert {:ok, []} =
               DpExchange.Schwab.get_transactions(@creds,
                 account_hash: "h",
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z],
                 types: ["TRADE"],
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, _prefs} =
               DpExchange.Schwab.get_user_preference(@creds,
                 plug: responding(%{}),
                 retry_attempts: 0
               )

      assert {:ok, _summaries} =
               DpExchange.Schwab.get_account_summaries(@creds,
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, _orders} =
               DpExchange.Schwab.get_all_orders(@creds,
                 from: ~U[2026-08-01 00:00:00Z],
                 to: ~U[2026-09-01 00:00:00Z],
                 plug: responding([]),
                 retry_attempts: 0
               )

      assert {:ok, _quote} =
               DpExchange.Schwab.get_symbol_quote("AAPL", @creds,
                 plug: responding(%{}),
                 retry_attempts: 0
               )

      assert {:ok, _hours} =
               DpExchange.Schwab.get_market("equity", @creds,
                 plug: responding(%{}),
                 retry_attempts: 0
               )

      assert {:ok, _instrument} =
               DpExchange.Schwab.get_instrument("037833100", @creds,
                 plug: responding(%{}),
                 retry_attempts: 0
               )

      assert {:ok, _transaction} =
               DpExchange.Schwab.get_transaction(@creds, "h", 1,
                 plug: responding(%{}),
                 retry_attempts: 0
               )

      assert DpExchange.Schwab.movers_universes() == Rest.movers_universes()
      assert DpExchange.Schwab.markets() == Rest.markets()
      assert DpExchange.Schwab.transaction_types() == Rest.transaction_types()
    end
  end
end
