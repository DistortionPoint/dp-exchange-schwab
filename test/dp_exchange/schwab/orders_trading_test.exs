defmodule DpExchange.Schwab.OrdersTradingTest do
  @moduledoc """
  The family's trading conventions, on this venue: an unproven write is `:order_unconfirmed`,
  a rejected preview is a refusal, an unknown request key is refused (`client_order_id`
  included), a replacement whose read-back failed is not papered over, and the order id and
  account option answer the same on the facade, `Rest` and the fake.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Order
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

  # Our own limiter saying no: nothing was sent.
  defmodule ThrottlingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 3_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # A limiter that cannot answer at all.
  defmodule BrokenLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :down}
    @impl true
    def check(_provider, _weight, _opts), do: {:error, :down}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @creds %{access_token: "at-1"}
  @buy %{symbol: "AAPL", side: :buy, quantity: 1, order_type: :market, time_in_force: :day}
  @option %{
    symbol: "XYZ   240315C00500000",
    instruction: "BUY_TO_OPEN",
    quantity: 10,
    order_type: :limit,
    time_in_force: :day,
    price: "6.45"
  }

  defp exploding(message), do: fn _conn -> raise message end

  defp located(conn, id) do
    conn |> Plug.Conn.put_resp_header("location", "/orders/#{id}") |> Plug.Conn.resp(201, "")
  end

  describe "an unproven write is {:error, {:order_unconfirmed, nil, reason}}" do
    test "a placement that drew a 5xx may have been placed" do
      plug = fn conn -> Plug.Conn.resp(conn, 503, "busy") end

      assert {:error, {:order_unconfirmed, nil, {:exchange_error, _provider, message}}} =
               Rest.place_order(@creds, "H", %{}, plug: plug, retry_attempts: 0)

      assert is_binary(message)
    end

    test "a placement whose transport failed after sending may have been placed" do
      plug = fn _conn -> raise "connection reset" end

      assert {:error, {:order_unconfirmed, nil, _reason}} =
               Rest.place_order(@creds, "H", %{}, plug: plug, retry_attempts: 0)
    end

    test "a replacement that drew a 5xx or failed in transport is unconfirmed too" do
      assert {:error, {:order_unconfirmed, nil, _reason}} =
               Rest.replace_order(@creds, "H", "1", %{},
                 plug: fn conn -> Plug.Conn.resp(conn, 502, "") end,
                 retry_attempts: 0
               )

      assert {:error, {:order_unconfirmed, nil, _reason}} =
               Rest.replace_order(@creds, "H", "1", %{},
                 plug: fn _conn -> raise "boom" end,
                 retry_attempts: 0
               )
    end

    test "a 2xx replacement with no Location was applied: unconfirmed, not a plain error" do
      assert {:error, {:order_unconfirmed, nil, :order_id_not_returned}} =
               Rest.replace_order(@creds, "H", "1", %{},
                 plug: fn conn -> Plug.Conn.resp(conn, 200, "") end,
                 retry_attempts: 0
               )

      # A Location ending in a slash names no order either.
      assert {:error, {:order_unconfirmed, nil, :order_id_not_returned}} =
               Rest.place_order(@creds, "H", %{},
                 plug: fn conn -> located(conn, "") end,
                 retry_attempts: 0
               )
    end

    test "the reason is bounded" do
      huge = String.duplicate("x", 50_000)
      plug = fn conn -> Plug.Conn.resp(conn, 500, huge) end

      assert {:error, {:order_unconfirmed, nil, {:exchange_error, _provider, message}}} =
               Rest.place_order(@creds, "H", %{}, plug: plug, retry_attempts: 0)

      assert byte_size(message) < 10_000
    end

    test "the facade says the same for a placement and a replacement" do
      opts = [account_hash: "H", plug: fn conn -> Plug.Conn.resp(conn, 500, "") end]

      assert {:error, {:order_unconfirmed, nil, _reason}} =
               Schwab.place_order(@creds, @buy, opts)

      assert {:error, {:order_unconfirmed, nil, _reason}} =
               Schwab.replace_order(@creds, "1", @buy, opts)

      no_location = [account_hash: "H", plug: fn conn -> Plug.Conn.resp(conn, 201, "") end]

      assert Schwab.place_order(@creds, @buy, no_location) ==
               {:error, {:order_unconfirmed, nil, :order_id_not_returned}}
    end

    test "a venue 4xx is a refusal, not unconfirmed" do
      plug = fn conn -> Plug.Conn.resp(conn, 400, ~s({"message":"bad"})) end

      assert {:refused, {:venue_error, 400, "bad"}} =
               Rest.place_order(@creds, "H", %{}, plug: plug, retry_attempts: 0)
    end

    test "EVERY 4xx but 429 is a refusal, undocumented ones included (DV6, BREAKING)" do
      for status <- [405, 406, 409, 410, 415, 422, 428] do
        plug = fn conn -> Plug.Conn.resp(conn, status, ~s({"message":"no"})) end

        assert {:refused, {:venue_error, ^status, "no"}} =
                 Rest.place_order(@creds, "H", %{}, plug: plug, retry_attempts: 0)

        assert {:refused, {:venue_error, ^status, "no"}} =
                 Rest.replace_order(@creds, "H", "1", %{}, plug: plug, retry_attempts: 0)

        assert {:refused, {:venue_error, ^status, "no"}} =
                 Rest.cancel_order(@creds, "H", "1", plug: plug, retry_attempts: 0)
      end
    end

    test "a 429 on a replace or a cancel stays a plain error, never a refusal" do
      plug = fn conn -> Plug.Conn.resp(conn, 429, "") end

      assert {:error, {:exchange_error, _provider, message}} =
               Rest.replace_order(@creds, "H", "1", %{}, plug: plug, retry_attempts: 0)

      assert message =~ "Rate limited by the venue"

      assert {:error, {:exchange_error, _provider, message}} =
               Rest.cancel_order(@creds, "H", "1", plug: plug, retry_attempts: 0)

      assert message =~ "Rate limited by the venue"
    end

    test "our own limiter refusing, or the venue's 429, is a plain error: nothing took effect" do
      Config.put_override(:rate_limit_module, ThrottlingLimiter)
      boom = exploding("a throttled write was sent")

      assert {:error, {:exchange_error, _provider, message}} =
               Rest.place_order(@creds, "H", %{}, plug: boom, retry_attempts: 0)

      assert message =~ "Throttled by our own rate limiter"

      assert {:error, {:exchange_error, _provider, _message}} =
               Rest.replace_order(@creds, "H", "1", %{}, plug: boom, retry_attempts: 0)

      Config.put_override(:rate_limit_module, BrokenLimiter)

      assert {:error, {:exchange_error, _provider, "Rate limiter unavailable"}} =
               Rest.place_order(@creds, "H", %{}, plug: boom, retry_attempts: 0)

      Config.put_override(:rate_limit_module, PermissiveLimiter)

      assert {:error, {:exchange_error, _provider, message}} =
               Rest.place_order(@creds, "H", %{},
                 plug: fn conn -> Plug.Conn.resp(conn, 429, "") end,
                 retry_attempts: 0
               )

      assert message =~ "Rate limited by the venue"
    end

    test "failures decided before anything is sent stay plain" do
      boom = exploding("an order that cannot be signed was sent")

      assert Rest.place_order(%{}, "H", %{}, plug: boom) ==
               {:error, {:missing_credentials, :schwab}}

      assert Rest.replace_order(%{}, "H", "1", %{}, plug: boom) ==
               {:error, {:missing_credentials, :schwab}}

      assert Rest.place_order(@creds, "", %{}, plug: boom) ==
               {:error, {:invalid_path_segment, :schwab}}
    end
  end

  describe "T9: a missing order is {:refused, :not_found}" do
    test "Rest reads, cancels and replaces a 404 as :not_found" do
      gone = fn conn -> Plug.Conn.resp(conn, 404, "") end

      assert Rest.get_order(@creds, "H", "1", plug: gone, retry_attempts: 0) ==
               {:refused, :not_found}

      assert Rest.cancel_order(@creds, "H", "1", plug: gone, retry_attempts: 0) ==
               {:refused, :not_found}

      assert Rest.replace_order(@creds, "H", "1", %{}, plug: gone, retry_attempts: 0) ==
               {:refused, :not_found}
    end

    test "a 404 with the venue's detail is still :not_found on a read" do
      gone = fn conn -> Plug.Conn.resp(conn, 404, ~s({"message":"no such order"})) end

      assert Rest.get_order(@creds, "H", "1", plug: gone, retry_attempts: 0) ==
               {:refused, :not_found}
    end

    test "other refusals keep their status and detail" do
      denied = fn conn -> Plug.Conn.resp(conn, 403, ~s({"message":"nope"})) end

      assert Rest.get_order(@creds, "H", "1", plug: denied, retry_attempts: 0) ==
               {:refused, {:venue_error, 403, "nope"}}

      assert Rest.cancel_order(@creds, "H", "1", plug: denied, retry_attempts: 0) ==
               {:refused, {:venue_error, 403, "nope"}}
    end

    test "the facade and the fake agree" do
      gone = fn conn -> Plug.Conn.resp(conn, 404, "") end
      opts = [account_hash: "H", plug: gone]

      assert Schwab.get_order(@creds, "1", opts) == {:refused, :not_found}
      assert Schwab.cancel_order(@creds, "1", opts) == {:refused, :not_found}
      assert Schwab.replace_order(@creds, "1", @buy, opts) == {:refused, :not_found}

      fake = [account_hash: "H"]
      assert Fake.get_order(@creds, "1", fake) == {:refused, :not_found}
      assert Fake.cancel_order(@creds, "1", fake) == {:refused, :not_found}
      assert Fake.replace_order(@creds, "1", @buy, fake) == {:refused, :not_found}
    end
  end

  describe "T6: a preview the venue rejects is {:refused, {:preview_rejected, rejects}}" do
    @rejected %{
      "orderStrategy" => %{"orderType" => "LIMIT"},
      "orderValidationResult" => %{
        "rejects" => [
          %{
            "validationRuleName" => "BUYING_POWER",
            "message" => "Insufficient buying power",
            "originalSeverity" => "REJECT"
          }
        ],
        "warns" => [%{"message" => "wide spread"}]
      }
    }

    test "Rest refuses a non-empty rejects list and carries the venue's detail rows" do
      plug = fn conn -> Req.Test.json(conn, @rejected) end

      assert {:refused, {:preview_rejected, [reject]}} =
               Rest.preview_order(@creds, "H", %{}, plug: plug, retry_attempts: 0)

      assert reject["validationRuleName"] == "BUYING_POWER"
      assert reject["message"] == "Insufficient buying power"
    end

    test "empty rejects, no validation result, and advisory warnings are a success" do
      for body <- [
            %{"orderValidationResult" => %{"rejects" => []}},
            %{"orderValidationResult" => %{"rejects" => [], "warns" => [%{"message" => "w"}]}},
            %{"orderStrategy" => %{}}
          ] do
        plug = fn conn -> Req.Test.json(conn, body) end

        assert {:ok, ^body} = Rest.preview_order(@creds, "H", %{}, plug: plug, retry_attempts: 0)
      end
    end

    test "a preview body that is not an object is unreadable, not a success" do
      assert {:error, :unexpected_response_shape} =
               Rest.preview_order(@creds, "H", %{},
                 plug: fn conn -> Req.Test.json(conn, []) end,
                 retry_attempts: 0
               )
    end

    test "the reject list is capped and its text bounded" do
      rows = for n <- 1..80, do: %{"message" => String.duplicate("y", 5_000), "n" => n}
      body = %{"orderValidationResult" => %{"rejects" => rows}}

      assert {:refused, {:preview_rejected, kept}} =
               Rest.preview_order(@creds, "H", %{},
                 plug: fn conn -> Req.Test.json(conn, body) end,
                 retry_attempts: 0
               )

      assert length(kept) == 50
      assert Enum.all?(kept, &(byte_size(&1["message"]) < 3_000))
    end

    test "a preview body keeps fractional numbers as Decimals, rejects included" do
      clean = ~s({"commissionAndFee":{"commission":{"value":1.10}}})

      assert {:ok, %{"commissionAndFee" => %{"commission" => %{"value" => value}}}} =
               Rest.preview_order(@creds, "H", %{},
                 plug: fn conn -> Plug.Conn.resp(conn, 200, clean) end,
                 retry_attempts: 0
               )

      assert value == Decimal.new("1.10")

      rejected =
        ~s({"orderValidationResult":{"rejects":[{"message":"m","limit":1.50,"tags":["a",2.5]}]}})

      assert {:refused, {:preview_rejected, [reject]}} =
               Rest.preview_order(@creds, "H", %{},
                 plug: fn conn -> Plug.Conn.resp(conn, 200, rejected) end,
                 retry_attempts: 0
               )

      assert reject["limit"] == Decimal.new("1.50")
      assert reject["tags"] == ["a", Decimal.new("2.5")]
    end

    test "the facade passes the refusal through" do
      plug = fn conn -> Req.Test.json(conn, @rejected) end

      opts = [account_hash: "H", plug: plug, retry_attempts: 0]

      assert {:refused, {:preview_rejected, [_reject]}} =
               Schwab.preview_order(@creds, @buy, opts)
    end

    test "the fake rejects an option order for a fractional quantity, in the same shape" do
      fractional = %{@option | quantity: "1.5"}

      assert {:refused, {:preview_rejected, [reject]}} =
               Fake.preview_order(@creds, fractional, account_hash: "H")

      assert reject["originalSeverity"] == "REJECT"
      assert is_binary(reject["validationRuleName"])
      assert is_binary(reject["message"])
    end

    test "the fake previews whole contracts and any equity order cleanly" do
      assert {:ok, %{"orderValidationResult" => %{"rejects" => []}}} =
               Fake.preview_order(@creds, @option, account_hash: "H")

      assert {:ok, %{"orderValidationResult" => %{"rejects" => []}}} =
               Fake.preview_order(@creds, %{@buy | quantity: "0.5"}, account_hash: "H")
    end

    test "a rejected preview does not place anything on the fake" do
      fractional = %{@option | quantity: "1.5"}

      assert {:refused, {:preview_rejected, _rejects}} =
               Fake.preview_order(@creds, fractional, account_hash: "H")

      window = [account_hash: "H", from: ~U[2026-01-01 00:00:00Z], to: ~U[2026-01-03 00:00:00Z]]
      assert {:ok, [%Order{id: "1005439821"}]} = Fake.get_orders(@creds, window)
    end
  end

  describe "T4: an unread request key is refused, client_order_id included" do
    test "every order call refuses it before anything is sent" do
      boom = exploding("an order with an ignored key was sent")
      request = Map.put(@buy, :client_order_id, "my-order-1")
      refused = {:error, {:unsupported_order_field, :client_order_id}}
      opts = [account_hash: "H", plug: boom]

      assert Schwab.place_order(@creds, request, opts) == refused
      assert Schwab.preview_order(@creds, request, opts) == refused
      assert Schwab.replace_order(@creds, "1", request, opts) == refused

      assert Fake.place_order(@creds, request, account_hash: "H") == refused
      assert Fake.preview_order(@creds, request, account_hash: "H") == refused
      assert Fake.replace_order(@creds, "1", request, account_hash: "H") == refused
    end

    test "the key is refused ahead of a missing account hash and credentials" do
      request = Map.put(@buy, :bogus, 1)

      assert Schwab.place_order(%{}, request, []) == {:error, {:unsupported_order_field, :bogus}}
      assert Fake.place_order(%{}, request, []) == {:error, {:unsupported_order_field, :bogus}}
    end
  end

  describe "T3: order type and time-in-force are required" do
    test "the facade and the fake refuse a request that leaves either out" do
      boom = exploding("an under-specified order was sent")

      for {field, key} <- [{:order_type, :order_type}, {:time_in_force, :time_in_force}] do
        request = Map.delete(@buy, field)
        refused = {:error, {:missing_field, key}}

        assert Schwab.place_order(@creds, request, account_hash: "H", plug: boom) == refused
        assert Schwab.preview_order(@creds, request, account_hash: "H", plug: boom) == refused
        assert Fake.place_order(@creds, request, account_hash: "H") == refused
        assert Fake.preview_order(@creds, request, account_hash: "H") == refused
      end
    end

    test "a limit price without an order type is not a market order" do
      boom = exploding("a typeless order was sent")
      request = @buy |> Map.delete(:order_type) |> Map.put(:price, 150)

      assert Schwab.place_order(@creds, request, account_hash: "H", plug: boom) ==
               {:error, {:missing_field, :order_type}}
    end
  end

  describe "T7: text sides and numeric-string quantities are accepted, floats are not" do
    test "the fake normalises a text side and reads a text quantity" do
      request = %{@buy | side: "Sell", quantity: "2"}

      assert {:ok, %Order{side: :sell} = order} =
               Fake.place_order(@creds, request, account_hash: "H")

      assert Decimal.equal?(order.quantity, 2)
    end

    test "a float quantity or price is refused by the facade and the fake alike" do
      boom = exploding("a float order was sent")
      opts = [account_hash: "H", plug: boom]

      assert Schwab.place_order(@creds, %{@buy | quantity: 1.5}, opts) ==
               {:error, {:invalid_quantity, 1.5}}

      assert Fake.place_order(@creds, %{@buy | quantity: 1.5}, account_hash: "H") ==
               {:error, {:invalid_quantity, 1.5}}

      limit = Map.merge(@buy, %{order_type: :limit, price: 150.5})

      assert Schwab.place_order(@creds, limit, opts) == {:error, {:invalid_price, 150.5}}

      assert Fake.place_order(@creds, limit, account_hash: "H") ==
               {:error, {:invalid_price, 150.5}}
    end

    test "a bad side is {:invalid_side, value}" do
      assert Schwab.place_order(@creds, %{@buy | side: "hold"}, account_hash: "H") ==
               {:error, {:invalid_side, "hold"}}

      assert Fake.place_order(@creds, %{@buy | side: :long}, account_hash: "H") ==
               {:error, {:invalid_side, :long}}
    end

    test "validation comes before the account option, the order ceiling and the credential" do
      broken = %{@buy | quantity: 0}

      assert Schwab.place_order(%{}, broken, []) == {:error, {:invalid_quantity, 0}}
      assert Fake.place_order(%{}, broken, []) == {:error, {:invalid_quantity, 0}}

      assert Schwab.place_order(%{}, @buy, []) == {:error, {:missing_option, :account_hash}}
    end
  end

  describe "T11: a replacement whose read-back failed is not an invented order" do
    test "the new id is carried with the reason" do
      plug = fn conn ->
        case conn.method do
          "PUT" -> located(conn, 9)
          "GET" -> Plug.Conn.resp(conn, 500, "")
        end
      end

      opts = [account_hash: "H", plug: plug]

      assert {:error, {:replace_accepted_unread, "9", {:exchange_error, _provider, _message}}} =
               Schwab.replace_order(@creds, "1", @buy, opts)
    end

    test "a refused read-back is reported the same way" do
      plug = fn conn ->
        case conn.method do
          "PUT" -> located(conn, 9)
          "GET" -> Plug.Conn.resp(conn, 404, "")
        end
      end

      opts = [account_hash: "H", plug: plug]

      assert Schwab.replace_order(@creds, "1", @buy, opts) ==
               {:error, {:replace_accepted_unread, "9", :not_found}}
    end

    test "an unreadable read-back body is reported the same way" do
      plug = fn conn ->
        case conn.method do
          "PUT" -> located(conn, 9)
          "GET" -> Req.Test.json(conn, %{})
        end
      end

      opts = [account_hash: "H", plug: plug]

      assert Schwab.replace_order(@creds, "1", @buy, opts) ==
               {:error, {:replace_accepted_unread, "9", {:missing_required_field, :id}}}
    end

    test "a readable read-back is the new order" do
      body = %{
        "orderId" => 9,
        "status" => "WORKING",
        "orderType" => "MARKET",
        "duration" => "DAY",
        "quantity" => 1,
        "orderLegCollection" => [
          %{"instruction" => "BUY", "quantity" => 1, "instrument" => %{"symbol" => "AAPL"}}
        ]
      }

      plug = fn conn ->
        case conn.method do
          "PUT" -> located(conn, 9)
          "GET" -> Req.Test.json(conn, body)
        end
      end

      opts = [account_hash: "H", plug: plug]

      assert {:ok, %Order{id: "9", status: :open, side: :buy}} =
               Schwab.replace_order(@creds, "1", @buy, opts)
    end

    test "a placement whose read-back failed is still a placed order, built from the payload" do
      plug = fn conn ->
        case conn.method do
          "POST" -> located(conn, 7)
          "GET" -> Plug.Conn.resp(conn, 500, "")
        end
      end

      request = Map.merge(@buy, %{side: "BUY", symbol: "MSFT", quantity: "3"})
      opts = [account_hash: "H", plug: plug]

      assert {:ok, %Order{id: "7", symbol: "MSFT", side: :buy, status: :pending} = order} =
               Schwab.place_order(@creds, request, opts)

      assert Decimal.equal?(order.quantity, 3)
      assert order.order_type == :market
      assert order.time_in_force == :day
    end
  end

  describe "T8: order ids" do
    test "nil, non-text, blank and padded ids are {:invalid_order_id, value} on every call" do
      boom = exploding("a request with an unusable order id was sent")
      opts = [account_hash: "H", plug: boom]

      for bad <- [nil, 7, :id, "", "   ", " 7", "7 ", "7\n"] do
        refused = {:error, {:invalid_order_id, bad}}

        assert Schwab.get_order(@creds, bad, opts) == refused
        assert Schwab.cancel_order(@creds, bad, opts) == refused
        assert Schwab.replace_order(@creds, bad, @buy, opts) == refused
      end
    end

    test "the id is judged before the account option, the order ceiling and the credential" do
      assert Schwab.get_order(%{}, nil, []) == {:error, {:invalid_order_id, nil}}

      assert Schwab.cancel_order(%{}, "", order_limit: :nobody_home) ==
               {:error, {:invalid_order_id, ""}}

      assert Schwab.replace_order(%{}, nil, %{}, []) == {:error, {:invalid_order_id, nil}}
    end

    test "a good id with no account option names the option" do
      assert Schwab.get_order(@creds, "1", []) == {:error, {:missing_option, :account_hash}}
      assert Schwab.cancel_order(@creds, "1", []) == {:error, {:missing_option, :account_hash}}
    end
  end

  describe "T12: a missing option is {:missing_option, key}" do
    test "a blank account hash is missing too" do
      for hash <- [nil, "", :h, 12] do
        assert Schwab.get_balances(@creds, account_hash: hash) ==
                 {:error, {:missing_option, :account_hash}}

        assert Fake.get_balances(@creds, account_hash: hash) ==
                 {:error, {:missing_option, :account_hash}}
      end
    end

    test "positions for a credential with several accounts need :account_number" do
      accounts = [
        %{"securitiesAccount" => %{"accountNumber" => "1", "positions" => []}},
        %{"securitiesAccount" => %{"accountNumber" => "2", "positions" => []}}
      ]

      plug = fn conn -> Req.Test.json(conn, accounts) end
      opts = [credentials: @creds, plug: plug, retry_attempts: 0]

      assert Schwab.get_positions(opts) == {:error, {:missing_option, :account_number}}
      assert {:ok, []} = Schwab.get_positions(opts ++ [account_number: "2"])
    end

    test "a credential with one account needs no number, on the facade and the fake" do
      accounts = [%{"securitiesAccount" => %{"accountNumber" => "1", "positions" => []}}]
      plug = fn conn -> Req.Test.json(conn, accounts) end

      assert {:ok, []} =
               Schwab.get_positions(credentials: @creds, plug: plug, retry_attempts: 0)

      assert {:ok, [_position]} = Fake.get_positions(credentials: @creds)
    end
  end
end
