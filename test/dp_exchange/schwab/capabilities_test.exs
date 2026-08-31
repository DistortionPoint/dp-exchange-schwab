defmodule DpExchange.Schwab.CapabilitiesTest do
  @moduledoc """
  The declaration is a claim about a real venue, so these tests check it against the
  documents it was derived from rather than against itself.

  Several assert an *absence* — `max_leverage` is nil, `:gtd` is not declared, `:ioc` is
  not an order type. Those are the ones worth having. A missing value is invisible in a
  passing suite unless something says out loud that it is meant to be missing, and every
  one of them is a place where a plausible substitute was available and refused.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, Timeframe, Venue}
  alias DpExchange.Schwab.Capabilities, as: Subject

  describe "the declaration is well-formed" do
    test "Core's own validation accepts it" do
      assert %Capabilities{} = Subject.declaration()
    end

    test "it names every Venue callback exactly once" do
      declared = Subject.declaration().endpoints |> Map.keys() |> Enum.sort()

      assert declared == Enum.sort(Venue.behaviour_info(:callbacks))
    end

    test "nothing is declared :proven, because nothing has been probed" do
      # D7: a specification says what a venue is documented to do, never what it does.
      # `:proven` needs a consumer trading live, which no amount of reading can supply.
      refute :proven in Map.values(Subject.declaration().endpoints)
    end

    test "everything the venue does not serve is declared :unsupported" do
      for endpoint <- Subject.venue_does_not_serve() do
        assert Subject.declaration().endpoints[endpoint] == :unsupported,
               "#{inspect(endpoint)} is listed as unserved but is not declared :unsupported"
      end
    end

    test "provenance says what was read and what was not measured" do
      caps = Subject.declaration()

      assert caps.measured_at == ~D[2026-08-31]
      assert caps.measured_against =~ "NOTHING IS PROBED"
      assert caps.measured_against =~ "Ceilings NOT measured"
      assert caps.measured_against =~ "401"
    end
  end

  describe "candle widths — the value 7.2 was blocked on" do
    test "eight widths, exactly the ones /pricehistory serves" do
      assert Subject.timeframes() == ~w(1m 5m 10m 15m 30m 1d 1w 1M)
      assert Subject.declaration().historical_timeframes == Subject.timeframes()
    end

    test "1w and 1M are declared even though Core cannot bucket them" do
      # Core models neither, deliberately: a weekly boundary depends on which weekday the
      # venue starts its week and a month is not a fixed number of seconds. That is a
      # reason not to bucket them, not a reason to hide that the venue serves them.
      assert Timeframe.seconds("1w") == :error
      assert Timeframe.seconds("1M") == :error

      assert "1w" in Subject.timeframes()
      assert "1M" in Subject.timeframes()
    end

    test "max_candles_per_request is nil — the cap is a period, not a bar count" do
      # periodType=day allows at most 10 days. How many bars that is depends on the width
      # and on whether extended hours are requested, so no single integer is true.
      assert Subject.declaration().max_candles_per_request == nil
    end
  end

  describe "the order vocabulary is mapped, not approximated" do
    test "the eight order types this venue serves, now that Core can name them" do
      # TRAILING_STOP, TRAILING_STOP_LIMIT, MARKET_ON_CLOSE and LIMIT_ON_CLOSE were real
      # order types with no Core atom; this list read as four and under-declared the venue.
      assert Subject.declaration().supported_order_types == [
               :market,
               :limit,
               :stop,
               :stop_limit,
               :trailing_stop,
               :trailing_stop_limit,
               :market_on_close,
               :limit_on_close
             ]
    end

    test ":ioc and :fok are time-in-force here, NOT order types" do
      # Schwab spells them as `duration` values. Declaring them as order types would
      # repeat the error already caught on Gemini in the other direction, where
      # `:post_only` was declared as a time-in-force.
      caps = Subject.declaration()

      refute :ioc in caps.supported_order_types
      refute :fok in caps.supported_order_types
      assert :ioc in caps.supported_time_in_force
      assert :fok in caps.supported_time_in_force
    end

    test ":post_only is absent — NON_MARKETABLE is close and is not the same thing" do
      refute :post_only in Subject.declaration().supported_order_types
    end

    test ":gtd is absent — three fixed horizons are not an arbitrary date" do
      # END_OF_WEEK, END_OF_MONTH and NEXT_END_OF_MONTH are what Schwab offers. A caller
      # asking for good-till-date cannot be served by picking the nearest of the three.
      refute :gtd in Subject.declaration().supported_time_in_force
    end
  end

  describe "margin — equities margin is not crypto margin" do
    test "margin is supported and leverage is :per_account, not a number" do
      caps = Subject.declaration()

      assert caps.supports_margin
      assert caps.max_leverage == :per_account
    end

    test "short selling is supported" do
      # `instruction` admits SELL_SHORT, SELL_SHORT_EXEMPT and BUY_TO_COVER.
      assert Subject.declaration().supports_short_selling
    end

    test "fractional shares are supported" do
      # `quantityType` admits DOLLARS, and a dollar-denominated order yields a fractional
      # share count.
      assert Subject.declaration().supports_fractional_shares
    end
  end

  describe "what the venue does not have" do
    test "no order book — no endpoint in either document returns depth" do
      assert {:get_order_book, 2} in Subject.venue_does_not_serve()
    end

    test "no fee schedule, and no money movement" do
      assert {:get_fees, 2} in Subject.venue_does_not_serve()
      assert {:get_transfers, 2} in Subject.venue_does_not_serve()
    end

    test "trading is NOT unsupported — the host supplies auth, and that is how it works" do
      # The package signs; the host obtains and holds the token. An authenticated endpoint
      # declared :unsupported because this repo holds no credential would be a claim about
      # the repo, not about the venue.
      caps = Subject.declaration()

      for endpoint <- [
            {:place_order, 3},
            {:cancel_order, 3},
            {:get_order, 3},
            {:get_orders, 2},
            {:get_balances, 2},
            {:get_accounts, 2}
          ] do
        assert caps.endpoints[endpoint] == :experimental,
               "#{inspect(endpoint)} must not be :unsupported — the venue serves it"
      end
    end

    test "get_trade_history is unsupported for a DIFFERENT reason, and it is separated" do
      # /transactions exists and carries fills. What is missing is a live response to
      # check the mapping against — this repo holds no credential and the venue has no
      # sandbox. Declaring it active would be a claim the code cannot honour; declaring
      # it unsupported without saying why would read as "the venue has no fills".
      assert Subject.declaration().endpoints[{:get_trade_history, 2}] == :unsupported
      assert {:get_trade_history, 2} in Subject.venue_does_not_serve()
    end

    test "get_symbols IS active — a pull needs a query, which is not the same as no pull" do
      # Core's contract asserts every venue can be pulled. Schwab has no list-everything
      # projection, so the pull requires a search term; refusing for want of a term is a
      # different thing from having no endpoint, and only the second would be
      # :unsupported.
      assert Subject.declaration().endpoints[{:get_symbols, 1}] == :experimental
      refute {:get_symbols, 1} in Subject.venue_does_not_serve()
    end
  end

  describe "what this venue taught Core to say" do
    test "preview and atomic replace are declared, because both are real here" do
      caps = Subject.declaration()

      assert caps.supports_order_preview
      assert caps.supports_order_replace
    end

    test "multi-leg is NOT declared, because the contract cannot build one" do
      # The venue has TRIGGER, OCO and net-priced spreads. `place_order/3` takes a flat
      # request, so declaring this true would advertise a path the facade cannot reach.
      refute Subject.declaration().supports_multi_leg_orders
    end

    test "sessions are declared, because this is the venue whose market closes" do
      caps = Subject.declaration()

      assert :pre_market in caps.supported_sessions
      assert :post_market in caps.supported_sessions
      assert length(caps.supported_sessions) > 1
    end

    test "catalog_access is :query_only, which is not the same as unsupported" do
      caps = Subject.declaration()

      assert caps.catalog_access == :query_only
      assert caps.endpoints[{:get_symbols, 1}] == :experimental
    end

    test "instrument types name what the venue trades, not the nearest crypto word" do
      # This read `[:spot]` with a comment saying it understated the venue. A declaration
      # that needs a comment to be true is what the struct exists to prevent.
      types = Subject.declaration().supported_instrument_types

      assert :option in types
      assert :future in types
      assert :mutual_fund in types
      assert length(types) > 1
    end
  end

  describe "shape of the venue" do
    test "credentials are required everywhere, market data included" do
      caps = Subject.declaration()

      assert caps.credential_benefit == :required
      assert caps.public_ceiling == nil
    end

    test "the ceiling is nil because there is no venue constant to declare" do
      # 0..120 order writes per minute per ACCOUNT, set per APPLICATION at registration.
      # A number here would be a claim about someone else's registration.
      assert Subject.declaration().authenticated_ceiling == nil
    end

    test "quotes stream, and volume is real" do
      caps = Subject.declaration()

      assert caps.streamable == [:quotes]
      assert caps.reports_trade_volume
    end

    test "the catalogue is vast and cannot be enumerated" do
      # GET /instruments has no list-everything projection; every lookup is a search.
      assert Subject.declaration().catalog_size == :vast
    end
  end
end
