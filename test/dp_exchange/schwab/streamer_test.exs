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

    test "LEVELONE_OPTIONS numbers differently from LEVELONE_EQUITIES" do
      # Field 1 is the description here and the bid there. The clearest case for per-service
      # maps: a shared table would decode every option's name as its bid price.
      {:ok, equities} = StreamerFields.for_service("LEVELONE_EQUITIES")
      {:ok, options} = StreamerFields.for_service("LEVELONE_OPTIONS")

      assert equities["1"] == :bid
      assert options["1"] == :description
      assert options["2"] == :bid
    end

    test "LEVELONE_FUTURES swaps the exchange ids relative to LEVELONE_EQUITIES" do
      # EQUITIES 6 => Ask ID, 7 => Bid ID. FUTURES 6 => Bid ID, 7 => Ask ID.
      # A shared map reports the bid's exchange as the ask's on every futures frame, and
      # both values are real exchange codes — nothing downstream notices.
      {:ok, equities} = StreamerFields.for_service("LEVELONE_EQUITIES")
      {:ok, futures} = StreamerFields.for_service("LEVELONE_FUTURES")

      assert equities["6"] == :ask_id
      assert equities["7"] == :bid_id
      assert futures["6"] == :bid_id
      assert futures["7"] == :ask_id
    end

    test "field 6 means three different things across three LEVELONE services" do
      {:ok, equities} = StreamerFields.for_service("LEVELONE_EQUITIES")
      {:ok, futures} = StreamerFields.for_service("LEVELONE_FUTURES")
      {:ok, forex} = StreamerFields.for_service("LEVELONE_FOREX")

      assert equities["6"] == :ask_id
      assert futures["6"] == :bid_id
      assert forex["6"] == :total_volume
    end

    test "options carry their sizes at 16-18, not at 4-5" do
      {:ok, options} = StreamerFields.for_service("LEVELONE_OPTIONS")

      assert options["16"] == :bid_size
      assert options["17"] == :ask_size
      assert options["18"] == :last_size
      # 4 is the last price on this service, and reading it as a bid size would be a price
      # in a quantity field.
      assert options["4"] == :last
    end

    test "futures options share the futures numbering, as the vendor documents" do
      {:ok, futures} = StreamerFields.for_service("LEVELONE_FUTURES")
      {:ok, futures_options} = StreamerFields.for_service("LEVELONE_FUTURES_OPTIONS")

      assert futures == futures_options
    end

    test "CHART_FUTURES is numbered differently from CHART_EQUITY starting at field 1" do
      # Transcribed from the vendor's own "2. CHART_FUTURES" table
      # (market-data-production.txt, after line 2439): 0 key, 1 Chart Time (ms since
      # epoch), 2 Open, 3 High, 4 Low, 5 Close, 6 Volume — one field shifted from
      # CHART_EQUITY's 0 key, 1 Open, 2 High, 3 Low, 4 Close, 5 Volume, 6 Sequence,
      # 7 Chart Time.
      #
      # This is the regression for the live defect: CHART_FUTURES used to decode under
      # `@chart_equity`'s numbering, so field 1 (the futures bar's own Chart Time) was read
      # as `:open` and the real `:chart_time` was never found — every futures candle
      # failed as `{:error, :missing_venue_timestamp}`, silently, because nothing had ever
      # decoded a real CHART_FUTURES frame.
      assert {:ok, equity} = StreamerFields.for_service("CHART_EQUITY")
      assert {:ok, futures} = StreamerFields.for_service("CHART_FUTURES")

      assert equity["1"] == :open
      assert futures["1"] == :chart_time

      assert futures == %{
               "0" => :symbol,
               "1" => :chart_time,
               "2" => :open,
               "3" => :high,
               "4" => :low,
               "5" => :close,
               "6" => :volume
             }

      # The vendor's CHART_FUTURES table stops at field 6 — no sequence, no chart_day.
      refute Map.has_key?(futures, "7")
      refute Map.has_key?(futures, "8")
    end

    test "every decodable service is one the venue actually carries" do
      # A map for a service the venue does not publish would be dead code that looks live.
      for service <- StreamerFields.decodable() do
        assert service in StreamerProtocol.services()
      end
    end

    test "a service with no map is an error, never another service's numbering" do
      # ADMIN has no map: it is the login/logout channel and carries no market data. The
      # point is that a service without one errors rather than borrowing another's
      # numbering.
      assert {:error, {:no_field_map, "ADMIN"}} = StreamerFields.for_service("ADMIN")
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

  describe "the three book services" do
    test "all three share one field table, which is the vendor's own arrangement" do
      # The only place in the Streamer where a shared map is correct: the vendor documents
      # "Book Fields for Streamer" once and names the three services against it.
      {:ok, nyse} = StreamerFields.for_service("NYSE_BOOK")
      {:ok, nasdaq} = StreamerFields.for_service("NASDAQ_BOOK")
      {:ok, options} = StreamerFields.for_service("OPTIONS_BOOK")

      assert nyse == nasdaq
      assert nasdaq == options
      assert nyse["1"] == :snapshot_time
    end

    test "a book carries the VENUE's timestamp, unlike a LEVELONE frame" do
      fields = %{
        snapshot_time: 1_787_936_147_000,
        bids: [[10.50, 300, 2, []], [10.49, 100, 1, []]],
        asks: [[10.60, 200, 1, []]]
      }

      assert {:ok, %Types.OrderBook{} = book} = StreamerDecode.to_order_book(fields, "AAPL")

      assert book.timestamp == DateTime.from_unix!(1_787_936_147_000, :millisecond)
      assert book.symbol == "AAPL"
      assert book.provider == :schwab
    end

    test "the aggregate size survives, not a sum over the market makers" do
      # Those are different numbers when attribution is partial, and the aggregate is the
      # one the venue stands behind.
      fields = %{
        snapshot_time: 1_787_936_147_000,
        bids: [[10.50, 300, 2, [["NSDQ", 100, 1], ["ARCA", 50, 1]]]],
        asks: []
      }

      assert {:ok, book} = StreamerDecode.to_order_book(fields, "AAPL")
      assert [{price, size}] = book.bids
      assert Decimal.equal?(price, Decimal.new("10.50"))
      assert Decimal.equal?(size, Decimal.new("300"))
      refute Decimal.equal?(size, Decimal.new("150"))
    end

    test "a book with no snapshot time is REFUSED, not stamped on arrival" do
      assert {:error, :missing_venue_timestamp} =
               StreamerDecode.to_order_book(%{bids: [], asks: []}, "AAPL")
    end

    test "levels keep the venue's ordering" do
      fields = %{
        snapshot_time: 1_787_936_147_000,
        bids: [[10.49, 100, 1, []], [10.50, 300, 1, []]],
        asks: []
      }

      assert {:ok, book} = StreamerDecode.to_order_book(fields, "AAPL")
      assert [{first, _size1}, {second, _size2}] = book.bids
      assert Decimal.equal?(first, Decimal.new("10.49"))
      assert Decimal.equal?(second, Decimal.new("10.50"))
    end

    test "a level with no price is dropped rather than carried as nil" do
      fields = %{snapshot_time: 1_787_936_147_000, bids: [[nil, 100, 1, []]], asks: []}

      assert {:ok, book} = StreamerDecode.to_order_book(fields, "AAPL")
      assert book.bids == []
    end

    test "an empty side is an empty list and the sequence is nil" do
      fields = %{snapshot_time: 1_787_936_147_000, bids: [[10.50, 1, 1, []]], asks: []}

      assert {:ok, book} = StreamerDecode.to_order_book(fields, "AAPL")
      assert book.asks == []
      # No sequence on a book frame, so a caller cannot use it to detect a dropped update.
      assert book.sequence == nil
    end
  end

  describe "the screeners and account activity" do
    test "the screeners share a table and keep the parameters that produced the list" do
      # The same symbol returns a different list at a different sortField. A caller storing
      # results without them cannot tell two screens apart.
      {:ok, equity} = StreamerFields.for_service("SCREENER_EQUITY")
      {:ok, option} = StreamerFields.for_service("SCREENER_OPTION")

      assert equity == option
      assert equity["2"] == :sort_field
      assert equity["3"] == :frequency
      assert equity["4"] == :items
    end

    test "ACCT_ACTIVITY is keyed on strings for two of its fields, not numbers" do
      # The vendor names "seq" and "key" literally and numbers only the rest. A decoder
      # assuming every key is a number would drop both.
      {:ok, activity} = StreamerFields.for_service("ACCT_ACTIVITY")

      assert activity["seq"] == :sequence
      assert activity["key"] == :key
      assert activity["1"] == :account
      assert activity["2"] == :message_type
      assert activity["3"] == :message_data
    end

    test "the activity sequence survives renaming, because a replay is not a new fill" do
      # The vendor's own reason for the field: a client that reconnects can tell which
      # messages it already saw. Dropping it makes a replayed activity indistinguishable
      # from a new one — an order fill counted twice.
      {:ok, map} = StreamerFields.for_service("ACCT_ACTIVITY")

      renamed =
        StreamerProtocol.rename(
          %{"seq" => 42, "key" => "sub-1", "1" => "ACC", "2" => "OrderFill", "3" => "{}"},
          map
        )

      assert renamed[:sequence] == 42
      assert renamed[:message_type] == "OrderFill"
      # Left as the venue sent it: its shape depends on message_type and the vendor does not
      # publish a schema per type here.
      assert renamed[:message_data] == "{}"
    end

    test "fourteen of the fifteen services are decodable, and the gap is visible" do
      # A service with no map is undecoded, not undocumented. ADMIN carries no market data
      # — it is the login/logout channel, not a data service — so it is named in services/0
      # and has no field table, which is the gap being asserted.
      decodable = StreamerFields.decodable()

      assert length(decodable) == 14
      assert "ADMIN" not in decodable
      assert "ADMIN" in StreamerProtocol.services()
    end
  end
end
