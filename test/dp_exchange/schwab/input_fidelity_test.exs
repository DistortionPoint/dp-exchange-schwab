defmodule DpExchange.Schwab.InputFidelityTest do
  @moduledoc """
  Requests reach the venue as asked, through the limiter this package supervises, and
  answers are read for what they are rather than for what they resemble.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Schwab.Rest

  defmodule RecordingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    # Runs in the calling process, so the test reads what the request was metered against.
    @impl true
    def acquire(_provider, _weight, opts) do
      send(self(), {:metered_by, Keyword.get(opts, :limiter)})
      :ok
    end

    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, RecordingLimiter)
    :ok
  end

  @creds %{access_token: "at-1"}

  defp responding(body) do
    fn conn -> Req.Test.json(conn, body) end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path, conn.query_string})
      Req.Test.json(conn, body)
    end
  end

  describe "the facade meters every read through the supervised limiter" do
    test "get_market/3 is metered by DpExchange.Schwab.RateLimiter, not the default one" do
      _result =
        DpExchange.Schwab.get_market("equity", @creds, plug: responding(%{}), retry_attempts: 0)

      assert_received {:metered_by, DpExchange.Schwab.RateLimiter}
    end
  end

  describe "get_prices/3 — one /quotes request for many symbols" do
    test "three symbols go out in ONE request, and every symbol gets a result" do
      body = %{
        "AAPL" => %{"quote" => %{"lastPrice" => 227.5, "quoteTime" => 1_787_936_147_000}},
        "MSFT" => %{"quote" => %{"lastPrice" => 410.0, "quoteTime" => 1_787_936_147_000}}
      }

      assert {:ok, results} =
               Rest.get_prices(~w(AAPL MSFT NOPE), @creds,
                 plug: capturing(body, self()),
                 retry_attempts: 0
               )

      assert_received {:request, _path, query}
      refute_received {:request, _path, _query}

      assert URI.decode_query(query)["symbols"] |> String.split(",") |> Enum.sort() ==
               ~w(AAPL MSFT NOPE)

      assert {:ok, %Quote{symbol: "AAPL"}} = results["AAPL"]
      assert {:ok, %Quote{symbol: "MSFT"}} = results["MSFT"]
      assert results["NOPE"] == {:refused, :not_listed}
    end
  end

  describe "a last-trade price is dated by its trade" do
    test "venue_time is tradeTime when lastPrice is the price, not the newer quoteTime" do
      traded = 1_787_936_000_000
      quoted = 1_787_936_147_000

      body = %{
        "AAPL" => %{
          "quote" => %{"lastPrice" => 227.5, "tradeTime" => traded, "quoteTime" => quoted}
        }
      }

      assert {:ok, %Quote{venue_time: venue_time}} =
               Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)

      assert venue_time == DateTime.from_unix!(traded, :millisecond)
    end

    test "a mark is dated by the quote, because a mark is not a print" do
      traded = 1_787_936_000_000
      quoted = 1_787_936_147_000

      body = %{
        "AAPL" => %{"quote" => %{"mark" => 227.5, "tradeTime" => traded, "quoteTime" => quoted}}
      }

      assert {:ok, %Quote{venue_time: venue_time}} =
               Rest.get_price("AAPL", @creds, plug: responding(body), retry_attempts: 0)

      assert venue_time == DateTime.from_unix!(quoted, :millisecond)
    end
  end

  describe "an instrument search answer" do
    test "a body without `instruments` is not an empty match" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_symbols(@creds,
                 query: "AAPL",
                 plug: responding(%{"errors" => ["boom"]}),
                 retry_attempts: 0
               )
    end

    test "an empty body is still no match" do
      assert {:ok, []} =
               Rest.get_symbols(@creds, query: "ZZZZ", plug: responding(%{}), retry_attempts: 0)
    end
  end
end
