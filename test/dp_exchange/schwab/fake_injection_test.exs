defmodule DpExchange.Schwab.FakeInjectionTest do
  @moduledoc """
  Proves `Fake` actually consults `Core.FakeInjection` — the shared mechanism itself is
  tested in `dp_exchange_core`; this is the wiring, per function, in this package.

  This package had no wiring to that seam at all, and was the only one of the family's
  five venue packages without any. On the venue where **every** endpoint needs a
  credential and there is no sandbox to point tiers 2 and 3 at, tier 1 is the only tier
  that ever runs — so a consumer here had no way to exercise its own retry, circuit
  breaker or alerting code against this venue, and no way to write a dispatch-only test
  without assembling a credential map for every call.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.FakeInjection
  alias DpExchange.Schwab.Fake

  @credentials %{access_token: "at-1"}

  describe "whole-call injection reaches every function with a real success path" do
    test "get_price/2" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_price("AAPL", credentials: @credentials) == {:error, :injected}
    end

    test "get_top_of_book/2" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_top_of_book("AAPL", credentials: @credentials) == {:error, :injected}
    end

    test "get_historical_prices/4" do
      FakeInjection.fail_always(:schwab, {:error, :injected})

      assert Fake.get_historical_prices("AAPL", "1d", [], credentials: @credentials) ==
               {:error, :injected}
    end

    test "get_symbols/1" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_symbols(credentials: @credentials, query: "AA") == {:error, :injected}
    end

    test "market_status/1" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.market_status(credentials: @credentials) == {:error, :injected}
    end

    test "get_accounts/2" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_accounts(@credentials, []) == {:error, :injected}
    end

    test "get_balances/2" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_balances(@credentials, account_hash: "h") == {:error, :injected}
    end

    test "get_positions/1" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_positions(credentials: @credentials) == {:error, :injected}
    end

    test "place_order/3" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.place_order(@credentials, %{}, account_hash: "h") == {:error, :injected}
    end

    test "preview_order/3" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.preview_order(@credentials, %{}, account_hash: "h") == {:error, :injected}
    end

    test "replace_order/4" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.replace_order(@credentials, "1", %{}, account_hash: "h") == {:error, :injected}
    end

    test "cancel_order/3" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.cancel_order(@credentials, "1", account_hash: "h") == {:error, :injected}
    end

    test "get_order/3" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_order(@credentials, "1", account_hash: "h") == {:error, :injected}
    end

    test "get_orders/2" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_orders(@credentials, account_hash: "h") == {:error, :injected}
    end

    test "test_connection/2" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.test_connection(@credentials, []) == {:error, :injected}
    end
  end

  describe "queue_failures/2 pops one entry per call, then resumes normal behaviour" do
    test "one queued failure, then the fake answers again" do
      FakeInjection.queue_failures(:schwab, [{:error, :timeout}])

      assert Fake.get_price("AAPL", credentials: @credentials) == {:error, :timeout}
      assert {:ok, _quote} = Fake.get_price("AAPL", credentials: @credentials)
    end
  end

  describe "per-symbol targeting is real isolation" do
    # A symbol-specific override can never be satisfied by, or interfere with, a call for
    # a different symbol — the same rule this family applies everywhere a batch could
    # otherwise let one bad member take down the rest.
    test "an override for one symbol leaves every other symbol untouched" do
      FakeInjection.fail_always(:schwab, "MSFT", {:refused, :not_listed})

      assert Fake.get_price("MSFT", credentials: @credentials) == {:refused, :not_listed}
      assert {:ok, _quote} = Fake.get_price("AAPL", credentials: @credentials)
    end
  end

  describe "bypass_credentials/1 skips the venue-faithful refusal, for wiring-only tests" do
    # Every call on this venue is signed and there is no anonymous endpoint, so `Fake`
    # gates all of them on `credentials:`. A consumer testing pure dispatch or decode
    # logic should not have to construct a valid-looking credential for each one.
    test "a credentialed call answers without credentials once bypassed" do
      assert Fake.get_price("AAPL", []) == {:error, {:missing_credentials, :schwab}}

      FakeInjection.bypass_credentials(:schwab)

      assert {:ok, _quote} = Fake.get_price("AAPL", [])
    end

    test "the bypass does not leak into a process that did not ask for it" do
      FakeInjection.bypass_credentials(:schwab)
      assert {:ok, _quote} = Fake.get_price("AAPL", [])

      task =
        Task.async(fn ->
          # A task started outside this process's `$callers` chain sees no override.
          Process.delete(:"$callers")
          Fake.get_price("AAPL", [])
        end)

      assert Task.await(task) == {:error, {:missing_credentials, :schwab}}
    end
  end

  describe "subscribe/2 is not wired, and an injected get_price does not leak into it" do
    # `subscribe/2` built its pushed quote by calling the public `get_price/2`, which consults
    # `FakeInjection`; a failure a consumer queued for `get_price` made `subscribe/2` raise
    # `MatchError`. The real `subscribe/2` makes no price call at all.
    test "a venue-wide failure leaves subscribe/2 delivering" do
      FakeInjection.fail_always(:schwab, {:error, :injected})

      assert Fake.subscribe(["AAPL"], to: self()) == :ok
      assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Types.Quote{symbol: "AAPL"}}
    end

    test "update_symbols/2 likewise" do
      FakeInjection.fail_always(:schwab, {:error, :injected})

      assert Fake.update_symbols(["MSFT"], to: self()) == :ok
      assert_receive {:dp_exchange, :schwab, %DpExchange.Core.Types.Quote{symbol: "MSFT"}}
    end
  end

  describe "the fake refuses a symbol set the real feed refuses" do
    test "a pair-shaped symbol is refused by name and nothing is subscribed" do
      assert Fake.subscribe(["AAPL", "BTC-USD"], to: self()) ==
               {:error, {:invalid_symbols, ["BTC-USD"]}}

      assert Fake.coverage() == %{}
      refute_received {:dp_exchange, :schwab, _payload}
    end

    test "update_symbols/2 refuses before it clears what was subscribed" do
      :ok = Fake.subscribe(["AAPL"], to: self())

      assert Fake.update_symbols(["BTC-USD"], to: self()) ==
               {:error, {:invalid_symbols, ["BTC-USD"]}}

      assert Map.keys(Fake.coverage()) == ["AAPL"]
    end

    test "a symbol set that is not a list is refused" do
      assert Fake.subscribe(:AAPL) == {:error, {:invalid_symbols, :AAPL}}
      assert Fake.unsubscribe("AAPL") == {:error, {:invalid_symbols, "AAPL"}}
      assert Fake.update_symbols(5) == {:error, {:invalid_symbols, 5}}
    end

    test "a padded symbol is held as the real feed holds it" do
      assert Fake.subscribe([" aapl "], to: self()) == :ok
      assert Map.keys(Fake.coverage()) == ["AAPL"]
    end
  end
end
