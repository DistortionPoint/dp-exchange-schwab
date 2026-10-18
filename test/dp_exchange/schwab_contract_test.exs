defmodule DpExchange.SchwabContractTest do
  @moduledoc """
  Core's conformance suite, run against this package.
  """

  defmodule ContractLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Schwab,
    fake: DpExchange.Schwab.Fake,
    symbol_format: DpExchange.Schwab.SymbolFormat,
    sample_pairs: ~w(AAPL MSFT GOOGL),
    # Conformance group 41 (family reasons, 2026-10-14): a well-formed symbol the fake does
    # not list, and a credentials map whose first value carries a trailing newline.
    unlisted_symbol: "NOPEQ",
    padded_credentials: %{access_token: "test-token\n"},
    # `lib/vendor/` is third-party code, a patched websockex fork (see
    # `DpExchange.Schwab.Vendor.WebSockex`). The scanning assertions are written for this
    # family's own conventions, so they read `lib/dp_exchange` only, as Webull's do.
    package_root: "lib/dp_exchange",
    credentials: %{access_token: "test-token"},
    # Conformance group 42: the REAL `Schwab.place_order/3` (through `Orders.build/2` and
    # `Rest.place_order/4`), not the fake, answering a 503 to the only attempt an order write
    # gets. The base request is accepted as-is; one refused before sending (no `:order_type`)
    # never reaches the plug. The permissive limiter override is process-scoped, so this
    # stays async-safe.
    ambiguous_place_order: fn request ->
      DpExchange.Core.Config.put_override(
        :rate_limit_module,
        DpExchange.SchwabContractTest.ContractLimiter
      )

      DpExchange.Schwab.place_order(
        %{access_token: "test-token"},
        request,
        account_hash: "contract-account",
        plug: fn conn -> Plug.Conn.resp(conn, 503, "busy") end
      )
    end,
    # The options this venue's own endpoints require before its fake will answer at all.
    #
    # Without these, every fake-driven assertion that calls an account-scoped endpoint was
    # refused for the MISSING ACCOUNT before it reached the behaviour under test, and the
    # suite took that refusal as a legitimate answer and skipped. Assertion 24 is how it
    # surfaced: niling this package's fake balance currency on purpose left the suite green,
    # while the two venues that need no account went red. Assertion 17 had the same shape —
    # it strips credentials and expects a failure, and got one for the account rather than
    # the credential.
    #
    # The key is this venue's, not Core's. A table of `:account_id` / `:account_number` /
    # `:account_hash` inside the contract would be exactly the venue-specific knowledge the
    # contract exists to keep out of Core.
    endpoint_opts: %{
      {:get_balances, 2} => [account_hash: "contract-account"],
      {:get_orders, 2} => [account_hash: "contract-account"],
      {:place_order, 3} => [account_hash: "contract-account"],
      {:get_order, 3} => [account_hash: "contract-account"],
      {:cancel_order, 3} => [account_hash: "contract-account"]
    },
    # Conformance group 49: an order id nobody placed is `{:refused, :not_found}` on the Fake
    # and the real path alike (`Rest.get_order/4` and `Rest.cancel_order/4` map the venue's 404
    # to it). Schwab order ids are integers, so the id is one.
    unknown_order_id: "999999999999",
    # A replace on this venue is a whole new order (`Fake.replace_order/4` builds it with
    # `Orders.build/2`), so the suite's generic price-only edit is refused as missing its
    # symbol. The replacement is the placed order with a new price.
    order_args: %{
      order_changes: %{
        symbol: "AAPL",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: Decimal.new("1"),
        price: Decimal.new("2")
      }
    }
end
