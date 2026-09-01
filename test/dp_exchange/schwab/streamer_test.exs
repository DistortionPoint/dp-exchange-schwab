defmodule DpExchange.Schwab.StreamerTest do
  @moduledoc """
  The Streamer — the API this package spent a year saying the venue did not have.

  The assertions that matter most are the ones about **not guessing**: SUBS silently
  unsubscribes and has no safe default; the same field number means different things in
  different services; a LEVELONE frame carries bid, ask and last and only one of them is a
  traded price.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types
  alias DpExchange.Schwab.{StreamerDecode, StreamerFields, StreamerInfo, StreamerProtocol}

  @info %StreamerInfo{
    socket_url: "wss://streamer-api.schwab.com/ws",
    customer_id: "cust-1",
    correl_id: "corr-1",
    channel: "IO",
    function_id: "APIAPP"
  }

  describe "the bootstrap nothing could reach the socket without" do
    test "every field is read from the venue's userPreference response" do
      body = %{
        "streamerInfo" => [
          %{
            "streamerSocketUrl" => "wss://streamer-api.schwab.com/ws",
            "schwabClientCustomerId" => "cust-1",
            "schwabClientCorrelId" => "corr-1",
            "schwabClientChannel" => "IO",
            "schwabClientFunctionId" => "APIAPP"
          }
        ]
      }

      assert {:ok, info} = StreamerInfo.from_user_preference(body)
      assert info.socket_url == "wss://streamer-api.schwab.com/ws"
      assert info.customer_id == "cust-1"
      assert info.correl_id == "corr-1"
      assert info.channel == "IO"
      assert info.function_id == "APIAPP"
    end

    test "a bare object is read too, not only a list" do
      body = %{
        "streamerInfo" => %{
          "streamerSocketUrl" => "wss://x",
          "schwabClientCustomerId" => "c",
          "schwabClientCorrelId" => "r",
          "schwabClientChannel" => "IO",
          "schwabClientFunctionId" => "F"
        }
      }

      assert {:ok, _info} = StreamerInfo.from_user_preference(body)
    end

    test "a missing field is an error, not a nil carried into LOGIN" do
      # A LOGIN sent without SchwabClientCorrelId is refused with a message about the
      # connection rather than about the field, so a nil here surfaces as a connection fault.
      body = %{
        "streamerInfo" => [
          %{
            "streamerSocketUrl" => "wss://x",
            "schwabClientCustomerId" => "c",
            "schwabClientChannel" => "IO",
            "schwabClientFunctionId" => "F"
          }
        ]
      }

      assert {:error, {:incomplete_streamer_info, [:correl_id]}} =
               StreamerInfo.from_user_preference(body)
    end

    test "an empty string counts as missing" do
      body = %{
        "streamerInfo" => [
          %{
            "streamerSocketUrl" => "",
            "schwabClientCustomerId" => "c",
            "schwabClientCorrelId" => "r",
            "schwabClientChannel" => "IO",
            "schwabClientFunctionId" => "F"
          }
        ]
      }

      assert {:error, {:incomplete_streamer_info, [:socket_url]}} =
               StreamerInfo.from_user_preference(body)
    end

    test "a response with no streamerInfo is an error" do
      assert {:error, :no_streamer_info} = StreamerInfo.from_user_preference(%{})
    end
  end

  describe "the fifteen services this venue was said not to have" do
    test "every one the vendor documents is named" do
      services = StreamerProtocol.services()

      assert length(services) == 15

      for service <- ~w(LEVELONE_EQUITIES LEVELONE_OPTIONS LEVELONE_FUTURES NYSE_BOOK
                        NASDAQ_BOOK OPTIONS_BOOK CHART_EQUITY CHART_FUTURES
                        SCREENER_EQUITY SCREENER_OPTION ACCT_ACTIVITY ADMIN) do
        assert service in services, "#{service} is missing"
      end
    end

    test "all six commands are named" do
      assert StreamerProtocol.commands() == ~w(LOGIN LOGOUT SUBS UNSUBS ADD VIEW)
    end
  end

  describe "LOGIN" do
    test "carries the token in parameters, because a frame has no headers" do
      # A package reaching for its REST auth here would send a login the venue cannot read.
      request = StreamerProtocol.login(@info, "token-abc", 1)

      assert request["service"] == "ADMIN"
      assert request["command"] == "LOGIN"
      assert request["parameters"]["Authorization"] == "token-abc"
      assert request["parameters"]["SchwabClientChannel"] == "IO"
      assert request["parameters"]["SchwabClientFunctionId"] == "APIAPP"
    end

    test "carries the two identifiers the venue drops the connection without" do
      request = StreamerProtocol.login(@info, "token-abc", 1)

      assert request["SchwabClientCustomerId"] == "cust-1"
      assert request["SchwabClientCorrelId"] == "corr-1"
    end
  end

  describe "SUBS replaces and ADD accumulates" do
    test "there is no default command, because one of them silently unsubscribes" do
      # SUBS A,B,C then SUBS A leaves only A streaming. A package defaulting to SUBS for an
      # incremental subscribe drops every symbol the caller already asked for, and the
      # caller just sees the feed go quiet.
      assert {:ok, subs} =
               StreamerProtocol.subscribe(@info, "LEVELONE_EQUITIES", "SUBS", ~w(AAPL MSFT))

      assert subs["command"] == "SUBS"

      assert {:ok, add} =
               StreamerProtocol.subscribe(@info, "LEVELONE_EQUITIES", "ADD", ~w(GOOG))

      assert add["command"] == "ADD"
      assert subs["parameters"]["keys"] == "AAPL,MSFT"
      assert add["parameters"]["keys"] == "GOOG"
    end

    test "LOGIN is refused here — it is an ADMIN command with no keys" do
      # Accepting it would build a subscription request carrying `keys`, which the venue
      # rejects.
      assert {:error, {:not_a_subscription_command, "LOGIN"}} =
               StreamerProtocol.subscribe(@info, "LEVELONE_EQUITIES", "LOGIN", ~w(AAPL))
    end

    test "a service the venue does not carry is an error" do
      assert {:error, {:unknown_service, "LEVELONE_CRYPTO"}} =
               StreamerProtocol.subscribe(@info, "LEVELONE_CRYPTO", "SUBS", ~w(BTC))
    end

    test "fields are joined when given and omitted when not" do
      # Omitting them asks for the service's default set, which is the venue's choice.
      assert {:ok, with_fields} =
               StreamerProtocol.subscribe(@info, "LEVELONE_EQUITIES", "SUBS", ~w(AAPL),
                 fields: ~w(0 1 2 3)
               )

      assert with_fields["parameters"]["fields"] == "0,1,2,3"

      assert {:ok, without} =
               StreamerProtocol.subscribe(@info, "LEVELONE_EQUITIES", "SUBS", ~w(AAPL))

      refute Map.has_key?(without["parameters"], "fields")
    end

    test "the envelope is always the array form" do
      assert {:ok, request} =
               StreamerProtocol.subscribe(@info, "LEVELONE_EQUITIES", "SUBS", ~w(AAPL))

      assert %{"requests" => [^request]} = StreamerProtocol.envelope([request])
    end
  end

  describe "three frame kinds, and only one is data" do
    test "each is classified" do
      assert {:ok, :data, [_entry | _rest]} =
               StreamerProtocol.classify(%{"data" => [%{"service" => "LEVELONE_EQUITIES"}]})

      assert {:ok, :response, [_entry | _rest]} =
               StreamerProtocol.classify(%{"response" => [%{"service" => "ADMIN"}]})

      assert {:ok, :notify, [_entry | _rest]} =
               StreamerProtocol.classify(%{"notify" => [%{"heartbeat" => "1668715930582"}]})
    end

    test "a frame with none of the three is refused, not treated as data" do
      # A heartbeat read as a quote is a price that never traded.
      assert {:error, :unrecognised_frame} = StreamerProtocol.classify(%{"something" => []})
    end
  end

  describe "a response can arrive and still say no" do
    test "code 0 is success and everything else is not" do
      # A package checking only that a response arrived would treat a rejected LOGIN as a
      # successful one and then wait forever for data that never comes.
      assert StreamerProtocol.succeeded?(%{"content" => %{"code" => 0}})
      refute StreamerProtocol.succeeded?(%{"content" => %{"code" => 3, "msg" => "denied"}})
      refute StreamerProtocol.succeeded?(%{"content" => %{}})
      refute StreamerProtocol.succeeded?(%{})
    end

    test "the venue's message is carried, and nil means it gave none" do
      assert StreamerProtocol.failure_message(%{"content" => %{"msg" => "denied"}}) == "denied"
      assert StreamerProtocol.failure_message(%{"content" => %{"code" => 3}}) == nil
    end
  end

  describe "field numbers mean different things per service" do
    test "field 1 is the BID in LEVELONE_EQUITIES and the OPEN in CHART_EQUITY" do
      # This is the whole reason the maps are per service. One global table would decode a
      # candle's open as a bid on every chart frame.
      assert {:ok, level_one} = StreamerFields.for_service("LEVELONE_EQUITIES")
      assert {:ok, chart} = StreamerFields.for_service("CHART_EQUITY")

      assert level_one["1"] == :bid
      assert chart["1"] == :open
    end

    test "a service with no map is an error, never another service's numbering" do
      assert {:error, {:no_field_map, "NYSE_BOOK"}} = StreamerFields.for_service("NYSE_BOOK")
    end

    test "renaming drops numbers it has no name for" do
      # An unnamed field decoded under a guessed name is a real value in the wrong place.
      {:ok, map} = StreamerFields.for_service("LEVELONE_EQUITIES")

      renamed = StreamerProtocol.rename(%{"1" => 10.5, "2" => 10.6, "999" => "?"}, map)

      assert renamed == %{bid: 10.5, ask: 10.6}
      refute Map.has_key?(renamed, "999")
    end

    test "field 12 is the PREVIOUS day's close, and is named so" do
      # The vendor: "Previous day's closing price… updated from the DB at 3:30 AM ET."
      # Naming it :close would put yesterday's number under today's timestamp.
      {:ok, map} = StreamerFields.for_service("LEVELONE_EQUITIES")

      assert map["12"] == :previous_close
      refute map["12"] == :close
    end
  end

  describe "a LEVELONE frame is two facts, and only one is a traded price" do
    @observed ~U[2026-08-28 14:53:02Z]

    test "the quote's price is `last`, never the bid or a midpoint" do
      fields = %{last: 10.55, bid: 10.50, ask: 10.60, last_size: 100}

      assert {:ok, %Types.Quote{} = quote_} =
               StreamerDecode.to_quote(fields, "AAPL", @observed)

      assert Decimal.equal?(quote_.price, Decimal.new("10.55"))
      refute Decimal.equal?(quote_.price, Decimal.new("10.50"))
      assert quote_.provider == :schwab
    end

    test "no last means NO quote — bid and ask are resting orders" do
      assert {:error, :no_traded_price} =
               StreamerDecode.to_quote(%{bid: 10.50, ask: 10.60}, "AAPL", @observed)
    end

    test "the quote's volume is the trade's own size, not the day's aggregate" do
      fields = %{last: 10.55, last_size: 100, total_volume: 4_000_000}

      assert {:ok, quote_} = StreamerDecode.to_quote(fields, "AAPL", @observed)

      assert Decimal.equal?(quote_.volume, Decimal.new("100"))
      refute Decimal.equal?(quote_.volume, Decimal.new("4000000"))
    end

    test "the same frame gives a top of book with no price at all" do
      fields = %{last: 10.55, bid: 10.50, ask: 10.60, bid_size: 3, ask_size: 5}

      assert {:ok, %Types.TopOfBook{} = top} =
               StreamerDecode.to_top_of_book(fields, "AAPL", @observed)

      assert Decimal.equal?(top.bid, Decimal.new("10.50"))
      assert Decimal.equal?(top.ask, Decimal.new("10.60"))
      refute Map.has_key?(top, :price)
    end

    test "venue_time is nil and observed_at is ours, because the frame carries no stamp" do
      # The pair together is the only honest statement of freshness: "seen at" is not
      # "quoted at".
      assert {:ok, top} =
               StreamerDecode.to_top_of_book(%{bid: 1, ask: 2}, "AAPL", @observed)

      assert top.venue_time == nil
      assert top.observed_at == @observed
    end

    test "an absent side is nil, not zero" do
      assert {:ok, top} = StreamerDecode.to_top_of_book(%{bid: 10.50}, "AAPL", @observed)

      assert top.ask == nil
      assert top.ask_size == nil
    end
  end

  describe "chart frames" do
    test "chart_time is the bar's opening, in milliseconds" do
      fields = %{
        open: 10.0,
        high: 11.0,
        low: 9.5,
        close: 10.5,
        volume: 1000,
        chart_time: 1_787_936_147_000
      }

      assert {:ok, %Types.Candle{} = candle} =
               StreamerDecode.to_candle(fields, "AAPL", "1m")

      assert candle.opened_at == DateTime.from_unix!(1_787_936_147_000, :millisecond)
      assert candle.timeframe == "1m"
      assert Types.Candle.coherent?(candle)
    end

    test "a bar with no chart_time is REFUSED, not stamped on arrival" do
      # A chart bar wearing the arrival time is placed in the series at the wrong minute,
      # and every value in it is still real.
      assert {:error, :missing_venue_timestamp} =
               StreamerDecode.to_candle(%{open: 1, close: 1}, "AAPL", "1m")
    end

    test "a chart_time that is not an epoch is refused too" do
      assert {:error, :missing_venue_timestamp} =
               StreamerDecode.to_candle(%{chart_time: "this morning"}, "AAPL", "1m")
    end

    test "all four prices survive, which a Quote could not carry" do
      fields = %{open: 10.0, high: 11.0, low: 9.5, close: 10.5, chart_time: 1_787_936_147_000}

      assert {:ok, candle} = StreamerDecode.to_candle(fields, "AAPL", "1m")

      assert Decimal.equal?(candle.open, Decimal.new("10.0"))
      assert Decimal.equal?(candle.high, Decimal.new("11.0"))
      assert Decimal.equal?(candle.low, Decimal.new("9.5"))
      assert Decimal.equal?(candle.close, Decimal.new("10.5"))
    end
  end
end
