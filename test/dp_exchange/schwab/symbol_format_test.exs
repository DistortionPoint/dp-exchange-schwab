defmodule DpExchange.Schwab.SymbolFormatTest do
  @moduledoc """
  A symbol here names one instrument, so translation is nearly the identity — and the
  work is all in `validate/1`.

  ## Why translation and validation are separate functions

  `Core.SymbolNormalizer` requires `to_exchange_symbol/1` to be **total**: a consumer
  normalising a string for display must not have it raise, and the conformance suite
  asserts the round trip over arbitrary input. Refusal cannot live there.

  But a caller about to spend a request must refuse first, and on this venue the refusal
  is not academic. `BTC`, `ETH` and `SOL` are all real listed equity tickers, so a
  misrouted crypto pair has a *plausible wrong answer* waiting: an ETF holding nothing
  like the coin, quoted in dollars, indistinguishable downstream from a real price.

  So translation is total and `validate/1` judges. `Rest`, `Orders` and `Fake` call
  `validate/1`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Schwab.SymbolFormat

  describe "to_exchange_symbol/1 and to_canonical_symbol/1 are total" do
    test "normalise case and whitespace" do
      assert SymbolFormat.to_exchange_symbol("aapl") == "AAPL"
      assert SymbolFormat.to_exchange_symbol("  msft  ") == "MSFT"
      assert SymbolFormat.to_canonical_symbol("aapl") == "AAPL"
    end

    test "the round trip is the identity for real symbols" do
      for symbol <- ~w(AAPL BRK.B F GOOGL) do
        native = SymbolFormat.to_exchange_symbol(symbol)

        assert SymbolFormat.to_canonical_symbol(native) == symbol
      end
    end

    test "an option symbol keeps its padding, which is significant" do
      option = "XYZ   210115C00050000"

      assert SymbolFormat.to_exchange_symbol(option) == option
      assert SymbolFormat.to_canonical_symbol(option) == option
    end

    test "malformed input does NOT raise — the contract requires a total function" do
      # This is the assertion Core's conformance suite makes, restated here so the reason
      # for the split is visible from this file alone.
      for bad <- ["", "   ", "BTC-USD", "!!!", nil, :aapl, 42] do
        assert is_binary(SymbolFormat.to_exchange_symbol(bad))
        assert is_binary(SymbolFormat.to_canonical_symbol(bad))
      end
    end
  end

  describe "validate/1 accepts what the venue can be asked about" do
    test "plain tickers, normalised" do
      assert SymbolFormat.validate("AAPL") == {:ok, "AAPL"}
      assert SymbolFormat.validate("aapl") == {:ok, "AAPL"}
      assert SymbolFormat.validate("  msft ") == {:ok, "MSFT"}
      assert SymbolFormat.validate("F") == {:ok, "F"}
    end

    test "a share-class suffix is kept" do
      assert SymbolFormat.validate("BRK.B") == {:ok, "BRK.B"}
      assert SymbolFormat.validate("brk.b") == {:ok, "BRK.B"}
    end

    test "a well-formed option symbol passes through untouched" do
      option = "XYZ   210115C00050000"
      assert SymbolFormat.validate(option) == {:ok, option}
    end
  end

  describe "validate/1 refuses a crypto pair, because a plausible wrong answer exists" do
    test "pair-shaped input is refused on every separator" do
      for pair <- ~w(BTC-USD ETH-USD BTC/USD BTC_USD BTC:USD) do
        assert {:error, {:not_an_equity_symbol, ^pair}} = SymbolFormat.validate(pair)
      end
    end

    test "the base leg IS a listed ticker, which is the whole danger" do
      # `BTC` alone is legitimate — it is a real equity symbol. `BTC-USD` is not, and
      # nothing here may turn the second into the first.
      assert SymbolFormat.validate("BTC") == {:ok, "BTC"}
      assert {:error, _reason} = SymbolFormat.validate("BTC-USD")
    end
  end

  describe "validate/1 refuses everything else by name" do
    test "an empty symbol is named as empty, not as malformed" do
      assert {:error, {:empty_symbol, ""}} = SymbolFormat.validate("")
      assert {:error, {:empty_symbol, "   "}} = SymbolFormat.validate("   ")
    end

    test "too long, digits and punctuation" do
      for bad <- ~w(TOOLONG AAPL1 123 A..B AAPL.BBB) do
        assert {:error, {:not_an_equity_symbol, ^bad}} = SymbolFormat.validate(bad)
      end
    end

    test "a non-string is refused rather than crashing" do
      assert {:error, {:not_an_equity_symbol, nil}} = SymbolFormat.validate(nil)
      assert {:error, {:not_an_equity_symbol, :aapl}} = SymbolFormat.validate(:aapl)
    end
  end

  describe "option?/1 recognises the fixed 21-character shape" do
    test "well-formed options" do
      assert SymbolFormat.option?("XYZ   210115C00050000")
      assert SymbolFormat.option?("AAPL  260116C00250000")
    end

    test "the padding is part of the format, not decoration" do
      # Trimming the underlying produces a shorter string that is no longer valid.
      refute SymbolFormat.option?("XYZ 210115C00050000")
    end

    test "near-misses are not options" do
      refute SymbolFormat.option?("XYZ   210115X00050000")
      refute SymbolFormat.option?("XYZ   2101150005000")
      refute SymbolFormat.option?("AAPL")
      refute SymbolFormat.option?(nil)
    end
  end

  describe "the normaliser contract" do
    test "the behaviour is implemented, which is what makes it obligatory" do
      assert DpExchange.Core.SymbolNormalizer in (SymbolFormat.module_info(:attributes)[
                                                    :behaviour
                                                  ] || [])
    end
  end
end
