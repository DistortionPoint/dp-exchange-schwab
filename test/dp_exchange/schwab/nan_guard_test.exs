defmodule DpExchange.Schwab.NaNGuardTest do
  use ExUnit.Case, async: true

  alias DpExchange.Schwab.StreamerDecode

  # `Decimal.parse/1` requiring the whole string be consumed is not a sufficient guard on its
  # own: "NaN", "Inf" and "-Inf" all parse fully and case-insensitively, so each arrived as a
  # well-formed `Decimal` and flowed onward as a real bid or ask.
  #
  # That is worse than a raise, and it fails a long way from the cause. `Decimal.add(nan, 1)`
  # is NaN, so it poisons a consumer's arithmetic silently; `Decimal.compare(nan, _)` RAISES
  # `invalid_operation: operation on NaN`, in the consumer's own process, naming Decimal
  # rather than the venue that sent it. An Infinity is quieter still — it compares greater
  # than everything and never raises.
  #
  # `dp_exchange_webull` found this and guarded both of its copies. This package guarded neither
  # of its two.
  @observed_at ~U[2026-09-11 00:00:00Z]

  # Lowercase and mixed forms included deliberately: `Decimal.parse/1` is case-insensitive
  # here, so a guard that only matched the canonical spelling would let `"inf"` straight
  # through.
  @poison ["NaN", "nan", "-NaN", "Inf", "inf", "-Inf", "Infinity", "-Infinity"]

  describe "a NaN or Infinity from the venue is dropped, never admitted as a number" do
    for value <- @poison do
      test "#{value} in a LEVELONE bid is nil, not a Decimal" do
        fields = %{bid: unquote(value), ask: "100.5"}

        assert {:ok, top} = StreamerDecode.to_top_of_book(fields, "AAPL", @observed_at)
        assert top.bid == nil
        # The rest of the frame is untouched — one poisoned field must not discard a
        # perfectly good one beside it.
        assert Decimal.equal?(top.ask, Decimal.new("100.5"))
      end
    end

    for value <- @poison do
      test "#{value} as a LEVELONE last price refuses the quote rather than nilling it" do
        # The guard turns a NaN into `nil`, and what happens next depends on the type. A
        # `nil` bid is legitimate — `Core.Types.TopOfBook` says a one-sided book is real. A
        # `nil` PRICE is not: `Core.Types.Quote` lists `:price` in `@enforce_keys`, and
        # `Quote.new/1` refuses it in as many words, because "a nil here is what a decode bug
        # on a renamed venue field produces".
        #
        # `to_quote/3` built the struct literally, so that constructor never ran, and its only
        # guard was `when last != nil` in the head — which a poisoned string passes. This
        # package's own `Rest.build_quote/2` already used `required_decimal(raw_price, :price)`
        # for the same field on the other transport.
        fields = %{last: unquote(value), last_size: "10"}

        assert {:error, {:invalid_decimal, :price, unquote(value)}} =
                 StreamerDecode.to_quote(fields, "AAPL", @observed_at)
      end
    end

    test "a quote with a readable price still decodes, so the guard has not eaten it" do
      assert {:ok, quoted} = StreamerDecode.to_quote(%{last: "227.5"}, "AAPL", @observed_at)
      assert Decimal.equal?(quoted.price, Decimal.new("227.5"))
    end

    test "a poisoned last SIZE does not discard the price beside it" do
      # `:volume` is not enforced on `Core.Types.Quote`, so the same asymmetry applies one
      # field over: an unreadable size is `nil` and the quote still stands.
      assert {:ok, quoted} =
               StreamerDecode.to_quote(%{last: "227.5", last_size: "NaN"}, "AAPL", @observed_at)

      assert Decimal.equal?(quoted.price, Decimal.new("227.5"))
      assert quoted.volume == nil
    end

    test "a real number still decodes, so the guard has not eaten the happy path" do
      fields = %{bid: "99.5", ask: "100.5"}

      assert {:ok, top} = StreamerDecode.to_top_of_book(fields, "AAPL", @observed_at)
      assert Decimal.equal?(top.bid, Decimal.new("99.5"))
      assert Decimal.equal?(top.ask, Decimal.new("100.5"))
    end

    test "what a NaN would have done downstream, stated rather than assumed" do
      # The reason this guard exists rather than a comment saying "should not happen".
      {nan, ""} = Decimal.parse("NaN")

      assert Decimal.nan?(nan)
      # Silently poisons arithmetic...
      assert Decimal.add(nan, Decimal.new(1)) |> Decimal.nan?()
      # ...and raises on the comparison a consumer is most likely to reach for.
      assert_raise Decimal.Error, fn -> Decimal.compare(nan, Decimal.new(1)) end
    end
  end
end
