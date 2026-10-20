defmodule DpExchange.Schwab.TickApTimeTest do
  @moduledoc """
  Tick AP: the access token's clock.

  Three claims, each of which fails against the code as it stood:

  * `check_unexpired/1` has an edge toward EARLIER. A token with two seconds left is not sent;
    it cannot arrive alive, and the venue's clock is not ours. The Fake judges the same edge,
    because it asks the same function.
  * A refreshed token's `:expires_at` is dated from when the request was SENT, not from when
    the reply was read. Dating from the reply credited the token with the whole round trip.
  * A feed that outlives its access token says so, once per credential generation, instead of
    the first sign being a denied LOGIN on the next reconnect.
  """

  use DpExchange.Schwab.FeedCase, async: true

  alias DpExchange.Core.Notice
  alias DpExchange.Schwab.{Auth, Fake, Feed, Rest}

  @now ~U[2026-09-01 10:00:00Z]
  @expired {:error, {:credentials_expired, :schwab}}

  describe "Auth.check_unexpired_at/2: the skew runs toward earlier" do
    test "inside the skew is expired, just outside it is not" do
      assert Auth.check_unexpired_at(DateTime.add(@now, 5, :second), @now) == @expired
      assert Auth.check_unexpired_at(DateTime.add(@now, 1, :second), @now) == @expired
      assert Auth.check_unexpired_at(DateTime.add(@now, 6, :second), @now) == :ok
    end

    test "now and the past are expired" do
      assert Auth.check_unexpired_at(@now, @now) == @expired
      assert Auth.check_unexpired_at(DateTime.add(@now, -600, :second), @now) == @expired
    end

    test "check_unexpired/1 applies it to the real clock, and a request is refused unsent" do
      dying = %{access_token: "at-1", expires_at: DateTime.add(DateTime.utc_now(), 2)}
      assert Auth.check_unexpired(dying) == @expired

      exploding = fn _conn -> raise "a dying token must not be sent" end
      assert Rest.get_price("AAPL", dying, plug: exploding) == @expired
    end

    test "the Fake judges the edge exactly as the real path does" do
      dying = %{access_token: "at-1", expires_at: DateTime.add(DateTime.utc_now(), 2)}
      healthy = %{access_token: "at-1", expires_at: DateTime.add(DateTime.utc_now(), 600)}

      assert Fake.get_price("AAPL", credentials: dying) == @expired
      assert Fake.get_account_summaries(dying) == @expired
      assert {:ok, %DpExchange.Core.Types.Quote{}} = Fake.get_price("AAPL", credentials: healthy)
    end
  end

  describe "a refreshed token is dated from the send, not from the reply" do
    test "expires_at minus the venue's lifetime is not later than the moment the venue saw it" do
      parent = self()

      body = %{"access_token" => "at-2", "refresh_token" => "rt-2", "expires_in" => 1_800}

      plug = fn conn ->
        send(parent, {:handled_at, DateTime.utc_now()})
        # A slow venue. Dated from the reply, the token gained this much lifetime.
        Process.sleep(50)
        Req.Test.json(conn, body)
      end

      creds = %{
        access_token: "at-1",
        refresh_token: "rt-1",
        client_id: "cid",
        client_secret: "csec"
      }

      assert {:ok, renewed} = Auth.refresh(creds, plug: plug, retry_attempts: 0)
      assert_receive {:handled_at, handled_at}, 5_000

      issued_at = DateTime.add(renewed.expires_at, -1_800, :second)
      assert DateTime.compare(issued_at, handled_at) != :gt
    end
  end

  defp expiring_in(seconds) do
    Map.put(credentials(), :expires_at, DateTime.add(DateTime.utc_now(), seconds))
  end

  defp expiry_notice(timeout \\ 5_000) do
    receive do
      {:dp_exchange, :schwab, %Notice{kind: :credentials_expiring} = notice} -> notice
    after
      timeout -> :none
    end
  end

  describe "a feed that outlives its access token says so" do
    test "a lapsed token raises one :credentials_expired notice, not one per tick" do
      feed = start_feed(socket: fake_socket(), credentials: expiring_in(-600))

      send(feed, :resubscribe)

      assert %Notice{severity: :error, details: %{reason: :credentials_expired}} =
               notice = expiry_notice()

      # Core's own conformance judgement of the notice (group 45): kind, reason and message.
      assert Notice.conformance_faults(notice) == []
      assert notice.provider == :schwab

      send(feed, :resubscribe)
      assert expiry_notice(600) == :none
    end

    test "a token inside the refresh margin raises :credentials_expiring once" do
      feed = start_feed(socket: fake_socket(), credentials: expiring_in(60))

      send(feed, :resubscribe)

      assert %Notice{details: %{reason: :credentials_expiring, expires_in_s: seconds}} =
               notice = expiry_notice()

      assert seconds in 1..60
      assert Notice.conformance_faults(notice) == []

      send(feed, :resubscribe)
      assert expiry_notice(600) == :none
    end

    test "update_credentials/2 re-arms the notice for the new generation" do
      feed = start_feed(socket: fake_socket(), credentials: expiring_in(-600))

      send(feed, :resubscribe)
      assert %Notice{} = expiry_notice()

      assert :ok = Feed.update_credentials(feed, expiring_in(-300))
      send(feed, :resubscribe)
      assert %Notice{details: %{reason: :credentials_expired}} = expiry_notice()
    end

    test "a fresh token, and a credential that states no expiry, say nothing" do
      fresh = start_feed(socket: fake_socket(), credentials: expiring_in(1_700))
      send(fresh, :resubscribe)
      assert expiry_notice(600) == :none

      unstated = start_feed(socket: fake_socket(), credentials: credentials())
      send(unstated, :resubscribe)
      assert expiry_notice(600) == :none
    end
  end
end
