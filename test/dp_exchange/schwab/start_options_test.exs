defmodule DpExchange.Schwab.StartOptionsTest do
  @moduledoc """
  A start key the tree does not read is refused at every entry point, never ignored (tick AQ's
  family rule), against one table: `DpExchange.Schwab.Options.start_keys/0`.

  A misspelt `order_limit_per_minut:` would otherwise start a tree that refuses every order
  write for a reason the caller cannot see, and a misspelt `read_limit_per_minute:` one that
  runs at a ceiling nobody chose.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Fake, Feed, Options, Socket}
  alias DpExchange.Schwab.Supervisor, as: SchwabSupervisor

  @lib "lib/dp_exchange/schwab"

  describe "a misspelt start key is refused at each entry point" do
    test "the facade, the supervisor, the feed and the fake all name it" do
      for key <- [:order_limit_per_minut, :read_limt_per_minute, :symbls, :nmae] do
        refused = {:error, {:unknown_option, key}}
        opts = [{key, 1}]

        assert Schwab.start_link(opts) == refused
        assert SchwabSupervisor.start_link(opts) == refused
        assert Feed.start_link(opts) == refused
        assert Fake.start_link(opts) == refused
      end
    end

    test "a nil value is still a key, and the first offender is the one named" do
      assert Schwab.start_link(typo: nil) == {:error, {:unknown_option, :typo}}

      assert Schwab.start_link(symbols: [], first_typo: 1, second_typo: 2) ==
               {:error, {:unknown_option, :first_typo}}
    end

    test "child_spec/1 reaches the same refusal when its supervisor starts the child" do
      %{start: {module, function, args}} = Schwab.child_spec(typo: 1)

      assert apply(module, function, args) == {:error, {:unknown_option, :typo}}
    end

    test "options that are not a keyword list are refused, with credentials redacted" do
      secret = "START-SECRET-TOKEN"
      bad = %{credentials: %{access_token: secret}, symbols: []}

      for result <- [
            Schwab.start_link(bad),
            SchwabSupervisor.start_link(bad),
            Feed.start_link(bad),
            Fake.start_link(bad)
          ] do
        assert {:error, {:invalid_options, _echoed}} = result
        refute inspect(result) =~ secret
      end
    end

    test "nothing was started by a refused call" do
      name = :"start_options_#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_option, :typo}} = Schwab.start_link(name: name, typo: 1)
      assert Process.whereis(name) == nil
    end
  end

  describe "every documented start key is accepted" do
    test "the table is non-empty and every key passes the check, nil included" do
      keys = Options.start_keys()

      assert length(keys) > 20
      assert keys == Enum.uniq(keys)
      assert Options.check_start(Enum.map(keys, &{&1, nil})) == :ok
      assert Options.check_start([]) == :ok
    end

    test "a tree starts with the keys a host actually passes, and the fake agrees" do
      unique = System.unique_integer([:positive])

      opts = [
        name: :"so_sup_#{unique}",
        feed: :"so_feed_#{unique}",
        limiter: :"so_lim_#{unique}",
        order_limit: :"so_olim_#{unique}",
        ledger: :"so_led_#{unique}",
        order_limit_per_minute: 10,
        read_limit_per_minute: 60,
        symbols: [],
        start_delay_ms: 60_000,
        interval_ms: 60_000
      ]

      assert {:ok, pid} = Schwab.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      assert Fake.start_link(opts) == :ignore
    end
  end

  describe ":ssl_options, the WebSocket's TLS options" do
    @tls [verify: :verify_peer, cacertfile: "/etc/ssl/own-ca.pem", password: "KEY-PASSWORD"]

    test "a non-keyword value is refused at every entry point, and never echoed" do
      for bad <- ["tls", :verify_peer, 5, %{verify: :verify_peer}, [:verify_peer, password: "x"]] do
        refused = {:error, {:invalid_option, :ssl_options}}
        opts = [ssl_options: bad, symbols: []]

        assert Schwab.start_link(opts) == refused
        assert SchwabSupervisor.start_link(opts) == refused
        assert Feed.start_link(opts) == refused
        assert Fake.start_link(opts) == refused
      end
    end

    test "nil is silence and a keyword list, empty included, is accepted" do
      for tls <- [nil, [], @tls] do
        assert Options.check_start(ssl_options: tls) == :ok
        assert Fake.start_link(ssl_options: tls) == :ignore
      end
    end

    test "the option reaches the options Socket is started with, through the facade" do
      name = :"so_tls_#{System.unique_integer([:positive])}"

      assert {:ok, pid} =
               Schwab.start_link(
                 name: name,
                 symbols: [],
                 start_delay_ms: 60_000,
                 ssl_options: @tls
               )

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      state = :sys.get_state(SchwabSupervisor.feed_name(name: name))
      socket_opts = Feed.socket_options(state, %{}, "token", make_ref())

      assert Keyword.fetch!(socket_opts, :ssl_options) == @tls
      # `Socket` keeps the caller's list because it still verifies the peer.
      assert Socket.connection_opts(socket_opts)[:ssl_options] == @tls

      # Not carried in the readable state, so a crash report does not print the password.
      refute inspect(state, limit: :infinity) =~ "KEY-PASSWORD"
      refute Keyword.has_key?(state.opts, :ssl_options)
    end

    test "without it nothing is forwarded, and Socket's verified defaults apply" do
      name = :"so_tls_none_#{System.unique_integer([:positive])}"

      assert {:ok, pid} =
               Schwab.start_link(name: name, symbols: [], start_delay_ms: 60_000)

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      state = :sys.get_state(SchwabSupervisor.feed_name(name: name))
      socket_opts = Feed.socket_options(state, %{}, "token", make_ref())

      refute Keyword.has_key?(socket_opts, :ssl_options)
      assert Socket.connection_opts(socket_opts)[:ssl_options][:verify] == :verify_peer
    end

    test "a list that drops peer verification is not forwarded as one that does" do
      name = :"so_tls_unsafe_#{System.unique_integer([:positive])}"
      unsafe = [verify: :verify_none]

      assert {:ok, pid} =
               Schwab.start_link(
                 name: name,
                 symbols: [],
                 start_delay_ms: 60_000,
                 ssl_options: unsafe
               )

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :shutdown) end)

      state = :sys.get_state(SchwabSupervisor.feed_name(name: name))
      socket_opts = Feed.socket_options(state, %{}, "token", make_ref())

      assert Socket.connection_opts(socket_opts)[:ssl_options][:verify] == :verify_peer
    end
  end

  describe "the table covers the keys the code reads (a key added without it fails here)" do
    # Keys a function reads from a CALL's `opts`, not a start's: `subscribe/3`'s `:to` and
    # `:include_partial`.
    @call_keys [:to, :include_partial, :limit, :depth, :since]

    defp literal_keys(file, patterns) do
      source = File.read!(Path.join(@lib, file))

      patterns
      |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
      |> Enum.flat_map(fn [match] ->
        ~r/:([a-z_]+)/ |> Regex.scan(match, capture: :all_but_first) |> List.flatten()
      end)
      |> Enum.map(&String.to_atom/1)
      |> Enum.uniq()
    end

    test "Feed's reads of its start options are in the table" do
      read =
        literal_keys("feed.ex", [
          ~r/(?:Config\.opt|Keyword\.get|Keyword\.fetch!?)\((?:state\.)?opts, (:[a-z_]+)/,
          ~r/Keyword\.take\((?:state\.)?opts,\s*\[([^\]]*)\]/
        ]) -- @call_keys

      assert length(read) > 10
      # The TLS options are read by the feed (`Keyword.get(opts, :ssl_options)`) and forwarded.
      assert :ssl_options in read
      assert read -- Options.start_keys() == []
    end

    test "Supervisor's reads of its start options are in the table" do
      read =
        literal_keys("supervisor.ex", [
          ~r/(?:ceiling|declared\?|validate_ceiling!|process_name)\(opts, (:[a-z_]+)/,
          ~r/Config\.opt\(opts, (:[a-z_]+)/
        ])

      assert :order_limit_per_minute in read
      assert :read_limit_per_minute in read
      assert read -- Options.start_keys() == []
    end
  end
end
