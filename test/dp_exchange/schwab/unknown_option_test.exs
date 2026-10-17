defmodule DpExchange.Schwab.UnknownOptionTest do
  @moduledoc """
  A facade option the call does not read is refused by name, on the real facade and on the
  Fake alike, before anything is sent and before the Fake consults `FakeInjection`.

  `limt:` is the case that matters: ignored, it answers a different question than the one
  asked. The allowed keys live in one table, `DpExchange.Schwab.Options`, and both modules
  check against it through `DpExchange.Core.Options.check/2`.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.{Config, FakeInjection}
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Options}

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

  # Every facade function that answers an error for a bad option: its positional arguments, all
  # valid, so the option check is the first thing that can refuse.
  @answering [
    {:get_price, ["AAPL"]},
    {:get_top_of_book, ["AAPL"]},
    {:get_historical_prices, ["AAPL", "1d", []]},
    {:get_symbols, []},
    {:market_status, []},
    {:get_accounts, [@creds]},
    {:get_balances, [@creds]},
    {:place_order, [@creds, %{}]},
    {:preview_order, [@creds, %{}]},
    {:replace_order, [@creds, "1", %{}]},
    {:cancel_order, [@creds, "1"]},
    {:get_order, [@creds, "1"]},
    {:get_orders, [@creds]},
    {:get_all_orders, [@creds]},
    {:test_connection, [@creds]},
    {:refresh_credentials, [@creds]},
    {:subscribe, [["AAPL"]]},
    {:unsubscribe, [["AAPL"]]},
    {:update_symbols, [["AAPL"]]},
    {:subscribe_notices, []},
    {:update_credentials, [@creds]},
    {:get_positions, []},
    {:get_option_chain, ["AAPL"]},
    {:get_option_expirations, ["AAPL"]},
    {:get_screener, ["$SPX"]},
    {:get_transactions, [@creds]},
    {:get_transaction, [@creds, "H", 1]},
    {:get_account_summaries, [@creds]},
    {:get_symbol_quote, ["AAPL", @creds]},
    {:get_market, ["equity", @creds]},
    {:get_instrument, ["037833100", @creds]},
    {:get_user_preference, [@creds]}
  ]

  # The four reads that return a plain value have no error channel, so they raise instead.
  @plain_reads [:coverage, :wanted, :coverage_by_kind, :status]

  describe "the allowed-key table" do
    test "names every function this file drives, and no other" do
      driven = Enum.map(@answering, &elem(&1, 0)) ++ @plain_reads

      assert length(driven) == 36
      assert driven == Enum.uniq(driven)

      for function <- driven do
        assert is_list(Options.allowed(function)), "#{function} has no allowed-key entry"
      end
    end

    test "every function allows the shared transport keys" do
      for function <- Enum.map(@answering, &elem(&1, 0)) ++ @plain_reads do
        allowed = Options.allowed(function)

        for key <- DpExchange.Core.Options.transport_options() do
          assert key in allowed, "#{function} does not allow #{inspect(key)}"
        end
      end
    end

    test "the keys only the Fake reads are not allowed on the real facade" do
      assert :market_status in Options.fake_only(:market_status)
      refute :market_status in Options.allowed(:market_status)

      assert Schwab.market_status(credentials: @creds, market_status: :closed) ==
               {:error, {:unknown_option, :market_status}}

      assert Fake.market_status(credentials: @creds, market_status: :closed) == {:ok, :closed}
    end

    test "the chain filters are the ones the request is built from" do
      allowed = Options.allowed(:get_option_chain)

      for key <- DpExchange.Schwab.Rest.chain_option_keys() ++ [:contractType] do
        assert key in allowed
      end

      assert Options.check(:get_option_chain, strike_count: 5, contractType: "CALL") == :ok
    end
  end

  describe "a misspelt option on the real facade" do
    test "is refused by name, and nothing reaches the venue" do
      parent = self()

      plug = fn conn ->
        send(parent, {:reached_the_venue, conn.request_path})
        Plug.Conn.resp(conn, 200, "{}")
      end

      for {function, args} <- @answering do
        opts = [plug: plug, retry_attempts: 0, credentials: @creds, limt: 5]

        assert apply(Schwab, function, args ++ [opts]) == {:error, {:unknown_option, :limt}},
               "facade #{function}"
      end

      refute_receive {:reached_the_venue, _path}, 500
    end

    test "a nil-valued stray key is still a key" do
      for {function, args} <- @answering do
        assert apply(Schwab, function, args ++ [[limt: nil]]) ==
                 {:error, {:unknown_option, :limt}},
               "facade #{function}"
      end
    end

    test "the first stray key in the caller's order is the one named" do
      assert Schwab.get_price("AAPL", credentials: @creds, sinse: 1, limt: 2) ==
               {:error, {:unknown_option, :sinse}}
    end

    test "a positional argument is judged before the option" do
      assert Schwab.get_price("", limt: 5) == {:error, {:invalid_symbol, ""}}
      assert Schwab.cancel_order(@creds, " ", limt: 5) == {:error, {:invalid_order_id, " "}}
      assert Schwab.subscribe(:nope, limt: 5) == {:error, {:invalid_symbols, :nope}}

      assert Schwab.get_market("nowhere", @creds, limt: 5) ==
               {:error, {:unknown_market, "nowhere"}}
    end

    test "an option is judged before the credential and the account" do
      assert Schwab.get_price("AAPL", limt: 5) == {:error, {:unknown_option, :limt}}
      assert Schwab.get_balances(@creds, limt: 5) == {:error, {:unknown_option, :limt}}
    end

    test "the four plain-value reads raise instead of answering a plausible empty value" do
      for function <- @plain_reads do
        error = assert_raise ArgumentError, fn -> apply(Schwab, function, [[feeed: :x]]) end

        assert error.message =~ "unknown option :feeed"
      end
    end

    test "an option the call does read is not refused" do
      assert Schwab.update_symbols(["AAPL"], feed: :unknown_option_test_no_such_feed) ==
               {:error, :feed_not_started}

      assert Schwab.coverage(feed: :unknown_option_test_no_such_feed) == %{}

      assert Schwab.get_price("AAPL", credentials: %{}, market_data_url: "https://x.invalid") ==
               {:error, {:missing_credentials, :schwab}}
    end
  end

  describe "a misspelt option on the Fake" do
    test "is refused by name, exactly as the facade refuses it" do
      for {function, args} <- @answering do
        opts = [credentials: @creds, limt: 5]
        call = args ++ [opts]

        assert apply(Fake, function, call) == {:error, {:unknown_option, :limt}},
               "fake #{function}"

        assert apply(Fake, function, call) == apply(Schwab, function, call),
               "fake #{function} disagrees with the facade"
      end
    end

    test "is refused before the injection is consulted" do
      FakeInjection.fail_always(:schwab, {:error, :injected})

      for {function, args} <- @answering do
        refusal = apply(Fake, function, args ++ [[credentials: @creds, limt: 5]])

        assert refusal == {:error, {:unknown_option, :limt}}, "fake #{function}"
      end

      # The override is still queued: a call with only readable options meets it.
      assert Fake.get_price("AAPL", credentials: @creds) == {:error, :injected}
    end

    test "the four plain-value reads raise" do
      for function <- @plain_reads do
        error = assert_raise ArgumentError, fn -> apply(Fake, function, [[feeed: :x]]) end

        assert error.message =~ "unknown option :feeed"
      end
    end

    test "answers what the venue's own endpoint_opts need, and still refuses the probe" do
      assert Fake.get_price("AAPL", credentials: @creds, dp_contract_unknown_option: true) ==
               {:error, {:unknown_option, :dp_contract_unknown_option}}

      assert Fake.get_symbols(
               credentials: @creds,
               query: "A",
               dp_contract_unknown_option: true
             ) == {:error, {:unknown_option, :dp_contract_unknown_option}}

      assert {:ok, _quote} = Fake.get_price("AAPL", credentials: @creds)
    end
  end
end
