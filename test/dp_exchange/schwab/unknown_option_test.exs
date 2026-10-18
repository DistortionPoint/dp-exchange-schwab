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

  defmodule WeighingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    # The facade calls run in the caller's process, so `self()` here is the test.
    @impl true
    def acquire(_provider, weight, _opts), do: weigh(weight)
    @impl true
    def check(_provider, weight, _opts), do: weigh(weight)
    @impl true
    def record(_provider, _weight, _opts), do: :ok

    defp weigh(weight) do
      send(self(), {:weighed, weight})
      :ok
    end
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

  # The calls in `@answering` that send no HTTP request: their own keys and :credentials only.
  @no_request [
    :subscribe,
    :unsubscribe,
    :update_symbols,
    :subscribe_notices,
    :update_credentials
  ]

  @refresh_creds %{access_token: "a", refresh_token: "r", client_id: "c", client_secret: "s"}

  describe "the allowed-key table" do
    test "names every function this file drives, and no other" do
      driven = Enum.map(@answering, &elem(&1, 0)) ++ @plain_reads

      assert length(driven) == 36
      assert driven == Enum.uniq(driven)

      for function <- driven do
        assert is_list(Options.allowed(function)), "#{function} has no allowed-key entry"
      end
    end

    test "a call that sends a request allows the shared transport keys it reads" do
      shared = DpExchange.Core.Options.transport_options()
      requesting = Enum.map(@answering, &elem(&1, 0)) -- @no_request

      for function <- requesting, key <- shared -- [:environment, :base_url] do
        # An order write is one attempt (no wait to scale); a refresh is never retried.
        unread =
          cond do
            function in [:place_order, :replace_order, :cancel_order] -> [:retry_delay]
            function == :refresh_credentials -> [:retry_attempts, :retry_delay]
            true -> []
          end

        if key in unread do
          refute key in Options.allowed(function), "#{function} allows #{inspect(key)}"
        else
          assert key in Options.allowed(function), "#{function} does not allow #{inspect(key)}"
        end
      end
    end

    test "a call that sends no request allows its own keys and :credentials, no transport key" do
      shared = DpExchange.Core.Options.transport_options() -- [:credentials]

      for function <- @no_request ++ @plain_reads do
        allowed = Options.allowed(function)

        assert :credentials in allowed, "#{function} refuses :credentials"

        for key <- shared do
          refute key in allowed, "#{function} allows #{inspect(key)}"
        end
      end
    end

    test "a no-request call given timeout: 5_000 answers unknown_option, facade and Fake alike" do
      opts = [timeout: 5_000]
      refusal = {:error, {:unknown_option, :timeout}}

      for module <- [Schwab, Fake] do
        assert module.subscribe(["AAPL"], opts) == refusal
        assert module.unsubscribe(["AAPL"], opts) == refusal
        assert module.update_symbols(["AAPL"], opts) == refusal
        assert module.subscribe_notices(opts) == refusal
        assert module.update_credentials(@creds, opts) == refusal
      end
    end

    test "the plain-value reads raise on a transport key, and take :credentials" do
      for module <- [Schwab, Fake], function <- @plain_reads do
        error = assert_raise ArgumentError, fn -> apply(module, function, [[timeout: 5_000]]) end

        assert error.message =~ "unknown option :timeout"
      end

      assert Schwab.coverage(credentials: @creds, feed: :unknown_option_test_no_such_feed) == %{}
    end

    test "a refresh and an order write refuse the retry keys they cannot honour" do
      assert Schwab.refresh_credentials(@creds, retry_attempts: 0) ==
               {:error, {:unknown_option, :retry_attempts}}

      assert Fake.refresh_credentials(@creds, retry_delay: 10) ==
               {:error, {:unknown_option, :retry_delay}}

      for module <- [Schwab, Fake] do
        assert module.cancel_order(@creds, "1", account_hash: "H", retry_delay: 10) ==
                 {:error, {:unknown_option, :retry_delay}}
      end
    end

    test "max_body_bytes bounds a read: a body over the cap is refused, not held" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, String.duplicate("x", 65)) end

      assert {:error, {:exchange_error, :schwab, {:response_too_large, 64}}} =
               Schwab.get_accounts(@creds, plug: plug, retry_attempts: 0, max_body_bytes: 64)
    end

    test "max_body_bytes bounds an order write too" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, String.duplicate("x", 65)) end

      assert {:error, {:exchange_error, :schwab, {:response_too_large, 64}}} =
               Schwab.cancel_order(@creds, "1", account_hash: "H", plug: plug, max_body_bytes: 64)
    end

    test "max_retry_after_s reaches the request on an order write and on a refresh" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, "{}") end

      # Core validates the ceiling when the request starts, so a bad one raises only if the key
      # was forwarded. Accepted and dropped, both calls would have answered normally.
      assert_raise ArgumentError, ~r/max_retry_after_s/, fn ->
        Schwab.cancel_order(@creds, "1", account_hash: "H", plug: plug, max_retry_after_s: -1)
      end

      assert_raise ArgumentError, ~r/max_retry_after_s/, fn ->
        Schwab.refresh_credentials(@refresh_creds, plug: plug, max_retry_after_s: -1)
      end
    end

    test "weight reaches the limiter on a token refresh" do
      Config.put_override(:rate_limit_module, WeighingLimiter)
      plug = fn conn -> Plug.Conn.resp(conn, 200, "{}") end

      _refresh = Schwab.refresh_credentials(@refresh_creds, weight: 5, plug: plug)

      assert_received {:weighed, 5}
    end

    test "the two shared transport keys no Schwab call reads are refused, not ignored" do
      for key <- [:environment, :base_url] do
        for function <- Enum.map(@answering, &elem(&1, 0)) ++ @plain_reads do
          refute key in Options.allowed(function), "#{function} allows #{inspect(key)}"
        end

        assert Schwab.get_price("AAPL", [{key, "https://x.invalid"}, {:credentials, @creds}]) ==
                 {:error, {:unknown_option, key}}

        assert Fake.get_price("AAPL", [{key, "https://x.invalid"}, {:credentials, @creds}]) ==
                 {:error, {:unknown_option, key}}
      end
    end

    test "a shared transport key is forwarded to the request, not accepted and dropped" do
      Config.put_override(:rate_limit_module, WeighingLimiter)
      plug = fn conn -> Plug.Conn.resp(conn, 200, "{}") end

      # `:weight` is what the limiter is charged; it used to be allowed and never forwarded.
      _read = Schwab.get_accounts(@creds, weight: 7, plug: plug, retry_attempts: 0)
      assert_received {:weighed, 7}

      # The same on an order write, which keeps its own bucket and a single attempt.
      _write = Schwab.cancel_order(@creds, "1", account_hash: "H", weight: 9, plug: plug)

      assert_received {:weighed, 9}
    end

    test "a retry count on an order write is refused, not ignored" do
      parent = self()

      plug = fn conn ->
        send(parent, {:reached_the_venue, conn.request_path})
        Plug.Conn.resp(conn, 200, "{}")
      end

      calls = [
        {:place_order, [@creds, %{}]},
        {:replace_order, [@creds, "1", %{}]},
        {:cancel_order, [@creds, "1"]}
      ]

      for {function, args} <- calls,
          attempts <- [1, 3, "2", :infinity],
          module <- [Schwab, Fake] do
        opts = [plug: plug, account_hash: "H", retry_attempts: attempts]

        assert apply(module, function, args ++ [opts]) ==
                 {:error, {:unsupported_option, :retry_attempts}},
               "#{inspect(module)}.#{function} with #{inspect(attempts)}"
      end

      refute_receive {:reached_the_venue, _path}, 500
    end

    test "absent, nil and zero retry counts are not refused on an order write" do
      for function <- [:place_order, :replace_order, :cancel_order],
          opts <- [[], [retry_attempts: nil], [retry_attempts: 0]] do
        assert Options.check(function, opts) == :ok
        assert Options.check_fake(function, opts) == :ok
      end
    end

    test "a retry count is still accepted on a read, which may retry" do
      assert Options.check(:get_orders, retry_attempts: 3) == :ok
      assert Options.check(:preview_order, retry_attempts: 3) == :ok
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
        # `limt` leads: the first stray key in the caller's order is the one named, and a
        # no-request call refuses `plug` as well.
        opts = [limt: 5, plug: plug, credentials: @creds]

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
