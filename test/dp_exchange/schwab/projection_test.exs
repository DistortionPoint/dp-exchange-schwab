defmodule DpExchange.Schwab.ProjectionTest do
  @moduledoc """
  `GET /instruments` takes a `projection` from a closed enum of six
  (`docs/reference/schwab/openapi/market-data-production.openapi.json`, `QueryParamprojection`).
  One outside it is refused by name before a request is spent learning that, on the real
  facade and on the Fake alike, and each of the six is sent as given.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Config
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

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @creds %{access_token: "at-1"}
  @projections ~w(symbol-search symbol-regex desc-search desc-regex search fundamental)

  defp recording(parent, body) do
    fn conn ->
      send(parent, {:queried, conn.request_path, conn.query_string})
      Plug.Conn.resp(conn, 200, body)
    end
  end

  describe "Rest.fetch_projection/1" do
    test "defaults to symbol-search, and a forwarded nil is silence" do
      assert Rest.fetch_projection([]) == {:ok, "symbol-search"}
      assert Rest.fetch_projection(projection: nil) == {:ok, "symbol-search"}
    end

    test "accepts each of the venue's six" do
      for projection <- @projections do
        assert Rest.fetch_projection(projection: projection) == {:ok, projection}
      end
    end

    test "refuses anything else, an atom spelling of a valid one included" do
      for bad <- ["", "SYMBOL-SEARCH", "regex", :search, 1, ["search"]] do
        assert Rest.fetch_projection(projection: bad) == {:error, {:invalid_projection, bad}}
      end
    end
  end

  describe "the real facade" do
    test "refuses an unlisted projection and sends nothing" do
      plug = recording(self(), ~s({"instruments": []}))

      assert Schwab.get_symbols(
               credentials: @creds,
               query: "AAPL",
               projection: "bogus",
               plug: plug,
               retry_attempts: 0
             ) == {:error, {:invalid_projection, "bogus"}}

      refute_receive {:queried, _path, _query}, 500
    end

    test "sends each listed projection as given" do
      for projection <- @projections do
        plug = recording(self(), ~s({"instruments": [{"symbol": "AAPL"}]}))

        assert {:ok, ["AAPL"]} =
                 Schwab.get_symbols(
                   credentials: @creds,
                   query: "AAPL",
                   projection: projection,
                   plug: plug,
                   retry_attempts: 0
                 )

        assert_receive {:queried, "/marketdata/v1/instruments", query}, 5_000
        assert URI.decode_query(query) == %{"symbol" => "AAPL", "projection" => projection}
      end
    end

    test "a missing query is still judged before the projection" do
      assert Schwab.get_symbols(credentials: @creds, projection: "bogus") ==
               {:error, {:query_required, :schwab}}
    end
  end

  describe "the Fake" do
    test "refuses the same projection, in the same place" do
      assert Fake.get_symbols(credentials: @creds, query: "A", projection: "bogus") ==
               {:error, {:invalid_projection, "bogus"}}

      assert Fake.get_symbols(credentials: @creds, projection: "bogus") ==
               {:error, {:query_required, :schwab}}
    end

    test "answers each listed projection" do
      for projection <- @projections do
        assert {:ok, symbols} =
                 Fake.get_symbols(credentials: @creds, query: "A", projection: projection)

        assert is_list(symbols)
      end
    end
  end
end
