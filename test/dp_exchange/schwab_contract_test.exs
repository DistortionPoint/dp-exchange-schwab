defmodule DpExchange.SchwabContractTest do
  @moduledoc """
  Core's conformance suite, run against this package.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Schwab,
    fake: DpExchange.Schwab.Fake,
    symbol_format: DpExchange.Schwab.SymbolFormat,
    sample_pairs: ~w(AAPL MSFT GOOGL),
    credentials: %{access_token: "test-token"}
end
