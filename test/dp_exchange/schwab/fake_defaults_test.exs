defmodule DpExchange.Schwab.FakeDefaultsTest do
  @moduledoc """
  The fake's shorter arities, which a consumer's own test calls without an options list, and
  the one canned order it can always be asked for.

  A consumer who drops the trailing `opts` must get the same answer the full arity gives for
  `[]`: the refusal for what is missing, never a `FunctionClauseError` and never a success.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.Order
  alias DpExchange.Schwab.{Fake, Rest}

  @creds %{access_token: "at-1"}
  @buy %{symbol: "AAPL", side: :buy, quantity: 1, order_type: :market, time_in_force: :day}

  describe "reads and writes called without options" do
    test "get_top_of_book/1 has no credential map to read, and says so" do
      assert Fake.get_top_of_book("AAPL") == {:error, {:missing_credentials, :schwab}}
    end

    test "preview_order/2 and replace_order/3 name the account hash they were not given" do
      assert Fake.preview_order(@creds, @buy) == {:error, {:missing_option, :account_hash}}

      assert Fake.replace_order(@creds, "1005439821", @buy) ==
               {:error, {:missing_option, :account_hash}}
    end

    test "get_all_orders/1 refuses the missing window exactly as the real path does" do
      assert {:error, {:from_and_to_required, :schwab}} =
               expected = Rest.check_all_orders_window([])

      assert Fake.get_all_orders(@creds) == expected
    end
  end

  describe "the canned order" do
    test "is readable before anything has been placed, as the one filled AAPL buy" do
      assert {:ok, %Order{} = order} =
               Fake.get_order(@creds, "1005439821", account_hash: "H")

      assert order.id == "1005439821"
      assert order.symbol == "AAPL"
      assert order.side == :buy
      assert order.status == :filled
    end

    test "an id the fake never issued is not found, not the canned order" do
      assert Fake.get_order(@creds, "42", account_hash: "H") == {:refused, :not_found}
    end
  end

  describe "not served by this venue, called without options" do
    test "every shorter arity still answers :not_supported" do
      assert Fake.quote_conversion("USD", "EUR", 1) == {:error, :not_supported}
      assert Fake.get_deposit_address("BTC", "bitcoin") == {:error, :not_supported}
      assert Fake.estimate_withdrawal_fee("BTC", "bitcoin", 1) == {:error, :not_supported}
      assert Fake.withdraw("BTC", "bitcoin", 1, "addr") == {:error, :not_supported}
      assert Fake.request_approved_address("BTC", "bitcoin", "addr") == {:error, :not_supported}
    end
  end
end
