defmodule DpExchange.Schwab.SymbolFormat do
  @moduledoc """
  Canonical symbol to Schwab symbol, and back — internal.

  ## A symbol here is one instrument, not a pair

  This is the first venue in the family where that is true, and it is the whole of this
  module's difficulty. Every other package normalises `BTC-USD` to whatever the venue
  spells it as, because a crypto symbol names two things: what you are buying and what
  you are paying with. `AAPL` names one thing. What you pay with is not in the symbol; it
  is USD because the venue is a US broker.

  So there is nothing to split, nothing to join, and no separator to translate. The
  canonical form and the native form are the same string, and the work is entirely in
  **refusing** the ones that are not equity symbols rather than in transforming anything.

  ## Which is why this module is mostly a rejection

  A pair-shaped symbol reaching this venue is a routing bug — a host that meant to send
  `BTC-USD` to Gemini and sent it here. Passing it through would produce a `404` from
  Schwab, or worse a match: `BTC` is a real listed equity symbol, and so are `ETH` and
  `SOL`, all of them ETFs holding nothing like the coin. **A crypto pair silently
  resolving to an equity ticker is the exact failure this family exists to prevent** —
  every value stays plausible and only the meaning is wrong.

  `to_exchange_symbol/1` therefore returns `{:ok, native}` or `{:error, reason}` rather
  than a bare string, which is a deliberate difference from the crypto packages. A
  transformation that cannot fail can be a function returning a string; a validation
  cannot.

  ## Options are a different shape and are not handled here

  Schwab's option symbols are fixed-width and positional — six characters of underlying
  padded with spaces, six of expiry, one of call/put, eight of strike, as in
  `XYZ   210115C00050000`. They round-trip through nothing in `Core`, whose symbol
  vocabulary is a string that names an instrument. Option symbols are passed through
  untouched when they already look like one, and constructing them is not this package's
  job — a caller that has an option symbol got it from `/chains`.
  """

  @typedoc "A symbol as this package's callers spell it."
  @type canonical :: String.t()

  @typedoc "A symbol as Schwab spells it."
  @type native :: String.t()

  # Schwab option symbols are exactly 21 characters: 6 underlying, 6 yymmdd, 1 C/P,
  # 8 strike. The width is the identifier, which is why matching on it is safe.
  @option_length 21

  @behaviour DpExchange.Core.SymbolNormalizer

  @doc """
  Canonical to native — **total**, per `Core.SymbolNormalizer`.

  Translation only. On this venue a canonical symbol and a native symbol are the same
  string, so this normalises case and whitespace and returns what it was given otherwise.
  It does not judge, because the contract requires a total function and a translation that
  raises on bad input is not one.

  **Judging is `validate/1`'s job**, and callers that are about to spend a request use
  that instead. The split is deliberate: `Rest` and `Orders` must refuse a pair-shaped
  symbol before sending, while a consumer normalising a string for display must not have
  that blow up in its hands.
  """
  @impl true
  @spec to_exchange_symbol(canonical()) :: native()
  def to_exchange_symbol(symbol) when is_binary(symbol) do
    trimmed = String.trim(symbol)
    if option?(trimmed), do: trimmed, else: String.upcase(trimmed)
  end

  def to_exchange_symbol(other), do: to_string(other)

  @doc """
  Native to canonical — **total**, and the identity on anything `to_exchange_symbol/1`
  produced.

  It exists so the round trip is expressible and testable, not because it transforms
  anything. If Schwab ever returns a spelling that differs from what it accepts, this is
  where that is absorbed rather than at every call site.
  """
  @impl true
  @spec to_canonical_symbol(native()) :: canonical()
  def to_canonical_symbol(symbol) when is_binary(symbol) do
    trimmed = String.trim(symbol)
    if option?(trimmed), do: trimmed, else: String.upcase(trimmed)
  end

  def to_canonical_symbol(other), do: to_string(other)

  @doc """
  Whether `symbol` is something this venue can be asked about, and the native form if so.

  Returns `{:error, {:not_an_equity_symbol, symbol}}` for anything pair-shaped rather than
  letting it through. See the module doc: `BTC` is a listed ETF, so a crypto pair arriving
  here has a plausible wrong answer available, and a `404` would be the *lucky* outcome.

  This is what `Rest` and `Orders` call. `to_exchange_symbol/1` is the contract's total
  translation and does not refuse anything.
  """
  @spec validate(canonical()) :: {:ok, native()} | {:error, term()}
  def validate(symbol) when is_binary(symbol) do
    trimmed = String.trim(symbol)

    cond do
      trimmed == "" ->
        {:error, {:empty_symbol, symbol}}

      option?(trimmed) ->
        {:ok, trimmed}

      # A separator means the caller thinks this is a pair. It is not, and the venue has
      # equity tickers that would match the base leg.
      String.contains?(trimmed, ["-", "/", "_", ":"]) ->
        {:error, {:not_an_equity_symbol, symbol}}

      equity?(trimmed) ->
        {:ok, String.upcase(trimmed)}

      true ->
        {:error, {:not_an_equity_symbol, symbol}}
    end
  end

  def validate(other), do: {:error, {:not_an_equity_symbol, other}}

  @doc "Whether `symbol` is a Schwab option symbol by its fixed 21-character shape."
  @spec option?(String.t()) :: boolean()
  def option?(symbol) when is_binary(symbol) do
    String.length(symbol) == @option_length and
      String.match?(symbol, ~r/^[A-Z ]{6}\d{6}[CP]\d{8}$/)
  end

  def option?(_other), do: false

  # An equity ticker is 1-5 letters, optionally with a class suffix Schwab spells with a
  # dot (`BRK.B`). Deliberately narrow: anything outside it is refused rather than sent,
  # because a refusal names the problem and a 404 does not.
  defp equity?(symbol), do: String.match?(symbol, ~r/^[A-Za-z]{1,5}(\.[A-Za-z]{1,2})?$/)
end
