defmodule DpExchange.Schwab.FeedTest do
  @moduledoc """
  The feed's routing decision, and the two things a consumer can observe about it.

  ## What is actually being tested here

  This venue's feed has two routes — the Streamer, and a REST poll when the Streamer cannot
  be bootstrapped — and **the whole risk lives in which one a consumer is told it got.**
  A feed that fell back to polling and reported `:stream` would be the family's signature
  defect: a plausible value with the wrong meaning, invisible until somebody wondered why
  no depth ever arrived.

  So the assertions are about the seam, not the transport: `coverage/1` names the route it
  actually used, a bootstrap failure emits `:degraded` rather than failing silently, and the
  wanted set survives a subscription that has not delivered yet.

  ## Why `:socket` can be injected

  A pid passed as `:socket` skips the bootstrap. That is not a test-only hole in the design
  — `Feed` needs it on reconnect — and it is what lets the socket-bearing branches run
  without a WebSocket server. Where a test needs the *bootstrap* path, it drives the real
  one through a `plug`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Config, Notice, Types}
  alias DpExchange.Schwab.Feed

  @moduletag :capture_log

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

  @credentials %{
    access_token: "token-abc",
    refresh_token: "r",
    client_id: "c",
    client_secret: "s"
  }

  @user_preference %{
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

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  # A stand-in for the socket process. It is a real process so `is_pid/1` and the liveness
  # checks behave, and it never speaks — the feed's socket-side behaviour under test is what
  # it *sends*, not what comes back.
  defp fake_socket do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp start_feed(opts) do
    {:ok, feed} =
      Feed.start_link(
        Keyword.merge([name: nil, credentials: @credentials, subscriber: self()], opts)
      )

    on_exit(fn -> if Process.alive?(feed), do: GenServer.stop(feed, :normal) end)
    feed
  end

  describe "the route a consumer actually got" do
    test "an injected socket streams, and coverage says so only once something arrives" do
      feed = start_feed(socket: fake_socket())

      # Nothing has been delivered yet. Reporting the subscribed symbol as covered here is
      # exactly the claim `coverage/1` exists to refuse.
      assert Feed.subscribe(feed, ["AAPL"]) == :ok
      assert Feed.coverage(feed) == %{}

      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}

      assert Feed.coverage(feed) == %{"AAPL" => :stream}
      assert %{route: :stream} = Feed.status(feed)
    end

    test "a bootstrap that fails falls back to the poll and SAYS so" do
      # `/userPreference` refuses. The feed cannot stream, and a consumer that is not told
      # would spend the session wondering where depth went.
      feed = start_feed(plug: responding(%{"error" => "unauthorized"}, 401), retry_attempts: 0)

      assert_receive {:dp_exchange, :schwab,
                      %Notice{kind: :degraded, details: %{fallback: :internal_poll}}},
                     2_000

      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "a response without streamerInfo is a bootstrap failure, not an empty stream" do
      # 200, valid JSON, and no socket in it. This is the shape that would produce a feed
      # that connects to nothing while every status looks healthy.
      feed = start_feed(plug: responding(%{"accounts" => []}), retry_attempts: 0)

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 2_000
      assert details.reason =~ "no_streamer_info"
      assert %{route: :internal_poll} = Feed.status(feed)
    end

    test "credentials with no access token cannot bootstrap even when the call succeeds" do
      _feed =
        start_feed(
          credentials: %{},
          plug: responding(@user_preference),
          retry_attempts: 0
        )

      assert_receive {:dp_exchange, :schwab, %Notice{kind: :degraded, details: details}}, 2_000
      assert details.reason =~ "missing_credentials"
    end
  end

  describe "the wanted set is not the covered set" do
    test "a second subscribe does not drop a symbol that has not delivered yet" do
      # The bug this replaces: `subscribe/2` read the current set out of `coverage/1` and
      # re-sent the union. A symbol subscribed and not yet quoted is absent from coverage,
      # so the next subscribe silently unsubscribed it.
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL"])
      Feed.subscribe(feed, ["MSFT"])

      assert feed |> Feed.wanted() |> Enum.sort() == ["AAPL", "MSFT"]
    end

    test "unsubscribe removes from wanted and from coverage" do
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL", "MSFT"])
      send(feed, {:dp_exchange, :schwab, quote_for("AAPL")})
      assert_receive {:dp_exchange, :schwab, %Types.Quote{}}

      assert Feed.unsubscribe(feed, ["AAPL"]) == :ok
      assert Feed.wanted(feed) == ["MSFT"]
      assert Feed.coverage(feed) == %{}
    end

    test "update_symbols replaces rather than accumulating" do
      feed = start_feed(socket: fake_socket())

      Feed.subscribe(feed, ["AAPL"])
      assert Feed.update_symbols(feed, ["MSFT"]) == :ok
      assert Feed.wanted(feed) == ["MSFT"]
    end
  end

  describe "what reaches a subscriber" do
    test "a refusal reaches the subscriber and is not counted as coverage" do
      feed = start_feed(socket: fake_socket())
      Feed.subscribe(feed, ["AAPL"])

      send(feed, {:dp_exchange, :schwab, {:refused, "AAPL", :delisted}})

      assert_receive {:dp_exchange, :schwab, {:refused, "AAPL", :delisted}}
      assert Feed.coverage(feed) == %{}
    end

    test "notices reach a notice subscriber without the data channel" do
      feed = start_feed(socket: fake_socket())
      parent = self()
      watcher = spawn(fn -> relay(parent) end)

      assert Feed.subscribe_notices(feed, to: watcher) == :ok
      send(feed, {:dp_exchange, :schwab, Notice.new(:link_up, :schwab)})

      assert_receive {:relayed, {:dp_exchange, :schwab, %Notice{kind: :link_up}}}
    end

    test "a value with no symbol is delivered and does not enter coverage" do
      # `ACCT_ACTIVITY` and anything else without a symbol still reaches the subscriber.
      # Coverage is per symbol, so there is nothing to record — and inventing a key for it
      # would report a symbol nobody subscribed to.
      feed = start_feed(socket: fake_socket())

      send(feed, {:dp_exchange, :schwab, %{account: "123", event: "OrderFill"}})

      assert_receive {:dp_exchange, :schwab, %{event: "OrderFill"}}
      assert Feed.coverage(feed) == %{}
    end

    test "an unrecognised message is ignored rather than crashing the feed" do
      feed = start_feed(socket: fake_socket())
      send(feed, :something_else)
      assert Feed.wanted(feed) == []
    end

    test "an unknown call is refused rather than raising" do
      feed = start_feed(socket: fake_socket())
      assert GenServer.call(feed, :nonsense) == {:error, :unknown_call}
    end
  end

  describe "the poll route" do
    test "coverage on the poll route reports :internal_poll, never :stream" do
      # The whole point of the two routes being visible. A poll reporting `:stream` is the
      # substitution this family refuses.
      feed =
        start_feed(
          plug: fn conn ->
            if String.contains?(conn.request_path, "userPreference") do
              Plug.Conn.resp(conn, 401, "no")
            else
              Req.Test.json(conn, quote_body())
            end
          end,
          retry_attempts: 0,
          interval_ms: 50,
          start_delay_ms: 0,
          symbols: ["AAPL"]
        )

      assert_receive {:dp_exchange, :schwab, %Types.Quote{symbol: "AAPL"}}, 3_000
      assert Feed.coverage(feed) == %{"AAPL" => :internal_poll}
      assert %{route: :internal_poll} = Feed.status(feed)
    end
  end

  test "interval_ms is the documented default" do
    assert Feed.interval_ms() == 30_000
  end

  test "child_spec carries the configured name as its id" do
    assert %{id: :my_feed, type: :worker} = Feed.child_spec(name: :my_feed)
  end

  defp quote_for(symbol) do
    %Types.Quote{
      symbol: symbol,
      price: Decimal.new("100.5"),
      timestamp: DateTime.utc_now(),
      provider: :schwab
    }
  end

  defp quote_body do
    %{
      "AAPL" => %{
        "quote" => %{
          "lastPrice" => 227.5,
          "totalVolume" => 51_234_567,
          "quoteTime" => 1_787_936_147_000
        }
      }
    }
  end

  defp relay(parent) do
    receive do
      message ->
        send(parent, {:relayed, message})
        relay(parent)
    end
  end
end
