defmodule DpExchange.Schwab.FacadeDefaultsTest do
  @moduledoc """
  The facade called the short way, with no options list, as a consumer calls it.

  Nothing here starts a feed under the default name, so every streaming call answers as a
  package with nothing running does: a refusal by name for what needs a feed, an empty
  answer for what only reads one. Every REST call is made with no credential, so it is
  refused locally and no request leaves.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Schwab

  describe "streaming calls with no feed started" do
    test "what needs a feed is refused by name, what only reads one answers empty" do
      assert Schwab.subscribe(["AAPL"]) == {:error, :feed_not_started}
      assert Schwab.update_symbols(["AAPL"]) == {:error, :feed_not_started}
      assert Schwab.subscribe_notices() == {:error, :feed_not_started}

      assert Schwab.unsubscribe(["AAPL"]) == :ok
      assert Schwab.coverage() == %{}
      assert Schwab.coverage_by_kind() == %{}
      assert Schwab.wanted() == []
      assert Schwab.status() == %{}
    end

    test "symbols are judged before whether a feed runs, lower case included" do
      assert Schwab.subscribe(["BTC-USD"]) == {:error, {:invalid_symbols, ["BTC-USD"]}}
      assert Schwab.subscribe(["aapl"]) == {:error, :feed_not_started}
    end
  end

  describe "REST calls with no credential" do
    test "each is refused locally by name" do
      missing = {:error, {:missing_credentials, :schwab}}

      assert Schwab.get_accounts(%{}) == missing
      assert Schwab.test_connection(%{}) == missing
      assert Schwab.refresh_credentials(%{}) == missing
      assert Schwab.get_transaction(%{}, "ABCDEF", 1) == missing
      assert Schwab.get_account_summaries(%{}) == missing
      assert Schwab.get_instrument("037833100", %{}) == missing
      assert Schwab.get_user_preference(%{}) == missing
    end

    test "the reads that judge their arguments first still refuse without a request" do
      assert {:error, _reason} = Schwab.get_all_orders(%{})
      assert {:error, _reason} = Schwab.get_symbol_quote("AAPL", %{})
      assert {:error, _reason} = Schwab.get_market("equity", %{})
    end
  end
end
