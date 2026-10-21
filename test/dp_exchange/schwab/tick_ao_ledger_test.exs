defmodule DpExchange.Schwab.TickAoLedgerTest do
  @moduledoc """
  Tick AO, lens M: a crashed `Feed` is restarted from the supervisor's static options, which carry
  none of what consumers did afterwards. The tree's `Ledger` keeps the accepted changes, and the
  restarted feed reads them back.

  The route is an injected stand-in socket (the feed's own test seam), so nothing is dialled.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Notice
  alias DpExchange.Core.Types.Quote
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Credentials, Feed, Ledger}
  alias DpExchange.Schwab.Supervisor, as: SchwabSupervisor

  setup do
    test_pid = self()
    socket = spawn(fn -> forward(test_pid) end)
    on_exit(fn -> Process.exit(socket, :kill) end)

    name = :"ao_ledger_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {Schwab, :start_link, [[name: name, symbols: [], socket: socket]]},
      type: :supervisor
    })

    %{name: name}
  end

  test "a killed feed restarts with its wanted set and subscribers, and says so", %{name: name} do
    assert Schwab.subscribe(["AAPL", "MSFT"], name: name) == :ok
    assert Schwab.subscribe_notices(name: name) == :ok
    flush_socket_messages()

    new_feed = kill_feed(name)

    assert Enum.sort(Schwab.wanted(name: name)) == ["AAPL", "MSFT"]

    # Every subscriber is told, in the family's shape: a `:coverage_change` naming the symbols.
    assert_receive {:dp_exchange, :schwab,
                    %Notice{kind: :coverage_change, severity: :warning, details: details}},
                   5_000

    assert %{reason: :feed_restarted, symbols: ["AAPL", "MSFT"], symbol_count: 2} = details

    # The wanted set is re-asserted on the route.
    assert_receive {:socket_got, {:"$websockex_cast", {:subscribe_all, batch}}}, 5_000
    assert {"LEVELONE_EQUITIES", "SUBS", keys, []} = List.keyfind(batch, "LEVELONE_EQUITIES", 0)
    assert Enum.sort(keys) == ["AAPL", "MSFT"]

    # And the subscriber still receives deliveries.
    quote_struct = %Quote{
      symbol: "AAPL",
      price: Decimal.new("101.5"),
      observed_at: DateTime.utc_now(),
      provider: :schwab
    }

    send(new_feed, {:dp_exchange, :schwab, quote_struct})
    assert_receive {:dp_exchange, :schwab, %Quote{symbol: "AAPL"}}, 5_000
  end

  test "an unsubscribe is remembered, so a restart does not bring the symbol back", %{name: name} do
    assert Schwab.subscribe(["AAPL", "MSFT"], name: name) == :ok
    assert Schwab.unsubscribe(["MSFT"], name: name) == :ok

    kill_feed(name)

    assert Schwab.wanted(name: name) == ["AAPL"]
  end

  test "a refused change writes nothing to the ledger", %{name: name} do
    assert Schwab.subscribe(["AAPL"], name: name) == :ok
    ledger = SchwabSupervisor.ledger_name(name: name)
    feed = SchwabSupervisor.feed_name(name: name)
    before_refusal = Ledger.fetch(ledger)

    # Straight to the feed, so it is the feed that refuses.
    assert {:error, {:invalid_symbols, _symbols}} = Feed.subscribe(feed, ["BTC-USD"])

    assert {:error, {:invalid_subscriber, _subscriber}} =
             Feed.subscribe(feed, ["MSFT"], to: "nobody")

    assert {:error, {:invalid_symbols, _not_a_list}} = Feed.update_symbols(feed, :not_a_list)

    assert Ledger.fetch(ledger) == before_refusal
    assert before_refusal.wanted == ["AAPL"]
  end

  test "the credential in force survives a restart, inside its redacting struct", %{name: name} do
    assert Schwab.subscribe(["AAPL"], name: name) == :ok

    assert Schwab.update_credentials(%{access_token: "CANARY-ROTATED"}, name: name) == :ok

    ledger = SchwabSupervisor.ledger_name(name: name)
    assert %Credentials{access_token: "CANARY-ROTATED"} = Ledger.fetch(ledger).credentials
    refute inspect(:sys.get_state(ledger), limit: :infinity) =~ "CANARY"

    # The test is named for a restart: kill the feed and read the ledger again.
    kill_feed(name)
    assert %Credentials{access_token: "CANARY-ROTATED"} = Ledger.fetch(ledger).credentials
    refute inspect(:sys.get_state(ledger), limit: :infinity) =~ "CANARY"
  end

  defp kill_feed(name) do
    feed_name = SchwabSupervisor.feed_name(name: name)
    old = Process.whereis(feed_name)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}, 5_000
    await_new_feed(feed_name, old, 100)
  end

  defp await_new_feed(feed_name, old, attempts_left) do
    case Process.whereis(feed_name) do
      pid when is_pid(pid) and pid != old ->
        pid

      _not_yet when attempts_left > 0 ->
        Process.sleep(50)
        await_new_feed(feed_name, old, attempts_left - 1)

      _never ->
        flunk("the feed was not restarted")
    end
  end

  defp flush_socket_messages do
    receive do
      {:socket_got, _message} -> flush_socket_messages()
    after
      200 -> :ok
    end
  end

  defp forward(test_pid) do
    receive do
      message ->
        send(test_pid, {:socket_got, message})
        forward(test_pid)
    end
  end
end
