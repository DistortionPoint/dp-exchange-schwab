defmodule DpExchange.SchwabContractTest do
  @moduledoc """
  Core's conformance suite, run against this package.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Schwab,
    fake: DpExchange.Schwab.Fake,
    symbol_format: DpExchange.Schwab.SymbolFormat,
    sample_pairs: ~w(AAPL MSFT GOOGL),
    credentials: %{access_token: "test-token"},
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
      {:get_order, 3} => [account_hash: "contract-account"]
    }
end
