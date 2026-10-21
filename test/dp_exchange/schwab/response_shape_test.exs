defmodule DpExchange.Schwab.ResponseShapeTest do
  @moduledoc """
  **A response of the wrong JSON shape is an answer, never a raise.**

  `Core.Venue`'s error discipline is that a facade call answers and does not raise in the
  caller's process. Every facade read that decodes a body is fed bodies of the wrong kind - a
  list where an object is expected, an object where a list is, `null`, a string, an integer
  and a fractional number - through the FACADE with the HTTP layer replaced by a `plug:`.

  **A fractional JSON number is the sharp one.** Bodies are decoded with `floats: :decimals`,
  so `42.5` arrives as a `%Decimal{}`, which `is_map/1` and a `%{}` pattern both accept. It was
  read as an object with no keys: "not listed", an empty chain, a flat account, and a raise in
  `Access` or `Enum` on the way. Each row below names the bodies that must be exactly
  `{:error, :unexpected_response_shape}`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config

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

  @creds %{access_token: "t"}
  @window [from: ~U[2026-08-01 00:00:00Z], to: ~U[2026-09-01 00:00:00Z]]

  defp answering(body), do: fn conn -> Req.Test.json(conn, body) end

  # Options for the calls that take their credential from `opts`.
  defp base(body), do: [plug: answering(body), retry_attempts: 0, credentials: @creds]

  # Options for the calls that take the credential as an argument.
  defp plain(body), do: [plug: answering(body), retry_attempts: 0]

  defp answers_without_raising(label, fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error}
      end

    refute match?({:raised, _error}, result),
           "schwab: #{label} raised #{inspect(result)} - a response shape it did not " <>
             "expect must be refused, not raised in the caller's process"

    result
  end

  # Every wrong kind of body: a list, `null`, text, an integer, a fractional number (a
  # `%Decimal{}` once decoded) and an object.
  @list []
  @bodies [@list, nil, "text", 42, 42.5, %{}]

  defp object_wrong, do: [[], nil, "text", 42, 42.5]
  defp list_wrong, do: [nil, "text", 42, 42.5, %{}]
  defp either_wrong, do: [[], nil, "text", 42, 42.5, %{}]

  defp calls do
    v = DpExchange.Schwab

    [
      {"get_price/2", object_wrong(), &v.get_price("AAPL", base(&1))},
      {"get_top_of_book/2", object_wrong(), &v.get_top_of_book("AAPL", base(&1))},
      {"get_historical_prices/4", either_wrong(),
       &v.get_historical_prices("AAPL", "1d", [], base(&1))},
      {"get_symbols/1", object_wrong(), &v.get_symbols(base(&1) ++ [query: "A"])},
      {"market_status/1", either_wrong(), &v.market_status(base(&1))},
      {"get_accounts/2", list_wrong(), &v.get_accounts(@creds, plain(&1))},
      {"get_balances/2", either_wrong(),
       &v.get_balances(@creds, plain(&1) ++ [account_hash: "H"])},
      {"get_order/3", object_wrong(),
       &v.get_order(@creds, "1", plain(&1) ++ [account_hash: "H"])},
      {"get_orders/2", list_wrong(),
       &v.get_orders(@creds, plain(&1) ++ [account_hash: "H"] ++ @window)},
      {"get_all_orders/2", list_wrong(),
       &v.get_all_orders(@creds, plain(&1) ++ @window ++ [now: ~U[2026-08-15 00:00:00Z]])},
      {"get_transactions/2", list_wrong(),
       &v.get_transactions(
         @creds,
         plain(&1) ++ [account_hash: "H", types: "TRADE"] ++ @window
       )},
      {"get_positions/1", list_wrong(), &v.get_positions(base(&1))},
      {"get_account_summaries/2", list_wrong(), &v.get_account_summaries(@creds, plain(&1))},
      {"test_connection/2", list_wrong(), &v.test_connection(@creds, plain(&1))},
      {"get_option_chain/2", object_wrong(), &v.get_option_chain("AAPL", base(&1))},
      {"get_option_expirations/2", object_wrong(), &v.get_option_expirations("AAPL", base(&1))},
      {"get_screener/2", object_wrong(), &v.get_screener("$DJI", base(&1))},
      {"get_symbol_quote/3", object_wrong(), &v.get_symbol_quote("AAPL", @creds, plain(&1))},
      {"get_market/3", object_wrong(), &v.get_market("equity", @creds, plain(&1))},
      {"get_instrument/3", object_wrong(), &v.get_instrument("037833100", @creds, plain(&1))},
      {"get_user_preference/2", [nil, "text", 42, 42.5],
       &v.get_user_preference(@creds, plain(&1))}
    ]
  end

  test "every facade read refuses the wrong kinds of body it names, and none raises" do
    assert length(calls()) == 21

    for {label, wrong, call} <- calls(), body <- wrong do
      result = answers_without_raising("#{label} on #{inspect(body)}", fn -> call.(body) end)

      assert result == {:error, :unexpected_response_shape},
             "#{label} answered #{inspect(result)} for the body #{inspect(body)}"
    end
  end

  test "no facade read raises on any wrong-kind body, whatever it answers" do
    for {label, _wrong, call} <- calls(), body <- @bodies do
      answers_without_raising("#{label} on #{inspect(body)}", fn -> call.(body) end)
    end
  end

  test "a fractional number nested where an object or a row is expected is refused too" do
    v = DpExchange.Schwab
    nested = fn field -> %{field => 42.5} end

    assert {:error, :unexpected_response_shape} =
             answers_without_raising("chain", fn ->
               v.get_option_chain("AAPL", base(nested.("callExpDateMap")))
             end)

    assert {:error, :unexpected_response_shape} =
             answers_without_raising("balances", fn ->
               body = nested.("securitiesAccount")
               v.get_balances(@creds, plain(body) ++ [account_hash: "H"])
             end)

    for rows <- [[42.5], [%{"orderId" => 1}, 42.5]] do
      assert {:error, :unexpected_response_shape} =
               answers_without_raising("orders #{inspect(rows)}", fn ->
                 v.get_orders(@creds, plain(rows) ++ [account_hash: "H"] ++ @window)
               end)
    end

    assert {:error, :unexpected_response_shape} =
             answers_without_raising("positions", fn ->
               v.get_positions(base([%{"securitiesAccount" => 42.5}]))
             end)
  end

  test "an order object with no id is its own refusal, not a wrong-shape one" do
    assert {:error, {:missing_required_field, :id}} =
             DpExchange.Schwab.get_order(@creds, "1", plain(%{}) ++ [account_hash: "H"])
  end
end
