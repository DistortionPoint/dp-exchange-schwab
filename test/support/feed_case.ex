defmodule DpExchange.Schwab.FeedCase do
  @moduledoc """
  The shared fixtures behind the feed test files, and why there is more than one file.

  `feed_test.exs` used to hold every feed test. Its slowest ones are slow on purpose — a
  call that must outlast `GenServer.call/2`'s five-second default, a read that must be
  answered *while* a bootstrap is still wedged, a fallback poll that must miss a whole
  cycle — and none of that waiting can be trimmed without deleting the thing being proved.

  ExUnit parallelises across FILES and serialises within one, so holding them together made
  every one of those waits run end to end: 15.4s of wall clock for 59 tests, against 4.8s
  for the other 400+. Split across four files the same waits overlap and the suite is paced
  by its single longest test rather than by their sum.

  Splitting that way is only worth doing if the files do not drift apart, which is what this
  template is for: one `PermissiveLimiter`, one `start_feed/1` with its teardown race
  already handled, one set of fixtures. A helper used by exactly one file stays in that file.
  """

  use ExUnit.CaseTemplate

  alias DpExchange.Core.{Config, DefaultRateLimiter, Types}
  alias DpExchange.Schwab.Feed

  using do
    quote do
      import DpExchange.Schwab.FeedCase

      @moduletag :capture_log
    end
  end

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

  @doc "The credential map every feed here is started with."
  @spec credentials() :: map()
  def credentials, do: @credentials

  @doc "A plug that answers `body` as JSON with `status`."
  @spec responding(term(), non_neg_integer()) :: (Plug.Conn.t() -> Plug.Conn.t())
  def responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  @doc """
  A stand-in for the socket process.

  It is a real process so `is_pid/1` and the liveness checks behave, and it never speaks —
  the feed's socket-side behaviour under test is what it *sends*, not what comes back.
  """
  @spec fake_socket() :: pid()
  def fake_socket do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  @doc "Starts an unnamed feed subscribed to the calling test, and tears it down after."
  @spec start_feed(keyword()) :: pid()
  def start_feed(opts) do
    {:ok, feed} =
      Feed.start_link(
        Keyword.merge([name: nil, credentials: @credentials, subscriber: self()], opts)
      )

    # `feed` is linked to THIS test process (plain `start_link`, no supervisor) and
    # on_exit callbacks run after the test process itself has already exited — so by the
    # time this runs, `feed` may already be gone, a race whose window `Feed` trapping
    # exits (added for the crash-isolation fix) widens: `Process.alive?/1` can still
    # answer `true` a moment before the same teardown catches up and the process is
    # gone by the time `GenServer.stop/2` actually reaches it. `:noproc` here means
    # cleanup has nothing left to do, not a test failure.
    on_exit(fn ->
      try do
        GenServer.stop(feed, :normal)
      catch
        :exit, _reason -> :ok
      end
    end)

    feed
  end

  @doc "A minimal streamed quote for `symbol`."
  @spec quote_for(String.t()) :: Types.Quote.t()
  def quote_for(symbol) do
    %Types.Quote{
      symbol: symbol,
      price: Decimal.new("100.5"),
      venue_time: DateTime.utc_now(),
      observed_at: DateTime.utc_now(),
      provider: :schwab
    }
  end

  @doc "The REST quote payload the poll route decodes."
  @spec quote_body() :: map()
  def quote_body do
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

  @doc """
  A named limiter generous enough that nothing under test is throttled.

  The bootstrap path (`Rest.get_user_preference/2`) reaches `Core.HttpClient`, which fails
  closed with "Rate limiter unavailable" when no limiter is named — so a test that means to
  exercise the Streamer bootstrap must supply one, or it silently measures the
  fallback-to-poll path instead. Learned the hard way while proving the blocking bug:
  without this the plug was never reached at all.
  """
  @spec permissive_limiter() :: atom()
  def permissive_limiter do
    name = :"limiter_#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      start_supervised(
        {DefaultRateLimiter,
         name: name, limits: %{schwab: %{limit: 1_000, per_ms: 1_000, burst: 1_000}}},
        id: name
      )

    name
  end
end
