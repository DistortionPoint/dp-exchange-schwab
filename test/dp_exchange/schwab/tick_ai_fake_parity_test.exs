defmodule DpExchange.Schwab.TickAiFakeParityTest do
  @moduledoc """
  The Fake carries every public function the facade does, with the same argument checks in
  the same order.

  Seven facade functions had no fake: the raw reads `get_transaction/4`,
  `get_account_summaries/2`, `get_symbol_quote/3`, `get_market/3`, `get_instrument/3` and
  `get_user_preference/2`, and `refresh_credentials/2`. A consumer who swapped the fake in
  met an `UndefinedFunctionError` on the real venue's own surface. The argument checks are
  the real modules' public `validate_*` functions, so the two cannot drift.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.FakeInjection
  alias DpExchange.Schwab
  alias DpExchange.Schwab.{Auth, Fake, Rest}

  @creds %{access_token: "at-1"}

  @refreshable %{
    access_token: "old-access",
    refresh_token: "old-refresh",
    client_id: "client",
    client_secret: "secret",
    note: "kept"
  }

  test "every function the facade exports exists on the Fake, with the same arity" do
    assert Schwab.__info__(:functions) -- Fake.__info__(:functions) == []
  end

  describe "refresh_credentials/2" do
    test "replaces both tokens, dates the expiry from :now and keeps the host's own keys" do
      now = ~U[2026-09-01 10:00:00Z]

      assert {:ok, renewed} = Fake.refresh_credentials(@refreshable, now: now)
      assert renewed.access_token == "fake-access-token-rotated"
      assert renewed.refresh_token == "fake-refresh-token-rotated"
      assert renewed.expires_at == ~U[2026-09-01 10:30:00Z]
      assert renewed.note == "kept"
      assert renewed.client_id == "client"
    end

    test "answers the same refusal as the real function for every unusable credential" do
      for bad <- [
            %{},
            %{access_token: "x"},
            %{@refreshable | client_secret: ""},
            %{@refreshable | refresh_token: " padded "},
            "not a map"
          ] do
        assert {:error, _reason} = expected = Auth.refresh(bad, [])
        assert Fake.refresh_credentials(bad) == expected
      end
    end

    test "a blank field is missing, judged before a padded one" do
      creds = %{@refreshable | client_id: "", refresh_token: " padded "}
      assert Fake.refresh_credentials(creds) == {:error, {:missing_credentials, :schwab}}
    end

    test "refuses a non-https token_url after the credential is judged" do
      assert Fake.refresh_credentials(@refreshable, token_url: "http://insecure.invalid/t") ==
               {:error, {:insecure_url, :schwab}}

      assert Fake.refresh_credentials(%{}, token_url: "http://insecure.invalid/t") ==
               {:error, {:missing_credentials, :schwab}}
    end

    test "refuses a :now that is not a DateTime exactly as the real function does" do
      for bad <- ["noon", 12, ~D[2026-09-01]] do
        expected = {:error, {:invalid_option, :now, bad}}
        assert Auth.refresh(@refreshable, now: bad) == expected
        assert Fake.refresh_credentials(@refreshable, now: bad) == expected
      end

      # After the credential, before the token URL, as the real function judges them.
      assert Fake.refresh_credentials(%{}, now: "noon") ==
               {:error, {:missing_credentials, :schwab}}

      insecure = [now: "noon", token_url: "http://insecure.invalid/t"]

      assert Fake.refresh_credentials(@refreshable, insecure) ==
               {:error, {:invalid_option, :now, "noon"}}
    end

    test "a forwarded now: nil is silence on the fake too" do
      assert {:ok, renewed} = Fake.refresh_credentials(@refreshable, now: nil)
      assert renewed.expires_at == DateTime.add(Fake.as_of(), 1800, :second)
    end

    test "consults FakeInjection first" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.refresh_credentials(@refreshable) == {:error, :injected}
    end
  end

  describe "get_transaction/4" do
    test "judges the path segments before the credential" do
      assert Rest.validate_transaction_path("", 1) == {:error, {:invalid_path_segment, :schwab}}

      assert Fake.get_transaction(%{}, "", 1) == {:error, {:invalid_path_segment, :schwab}}
      assert Fake.get_transaction(%{}, "H", nil) == {:error, {:invalid_path_segment, :schwab}}
    end

    test "then the credential" do
      assert Fake.get_transaction(%{}, "H", 1) == {:error, {:missing_credentials, :schwab}}
    end

    test "answers the venue's array holding the row get_transactions/2 lists" do
      assert {:ok, [%{"activityId" => 1, "type" => "TRADE"}]} =
               Fake.get_transaction(@creds, "H", 1)

      assert Fake.get_transaction(@creds, "H", "1") == Fake.get_transaction(@creds, "H", 1)
    end

    test "an id it does not hold is the venue's 404" do
      assert Fake.get_transaction(@creds, "H", 2) == {:refused, {:venue_error, 404}}
    end

    test "a non-binary account hash is refused by name, on the Fake and the real facade alike" do
      refusal = {:error, {:invalid_path_segment, :schwab}}

      assert Fake.get_transaction(@creds, 7, 1) == refusal
      assert Schwab.get_transaction(@creds, 7, 1) == refusal
      assert Fake.get_transaction(@creds, nil, 1) == refusal
      assert Schwab.get_transaction(@creds, nil, 1) == refusal
    end
  end

  describe "get_account_summaries/2" do
    test "needs a credential" do
      assert Fake.get_account_summaries(%{}) == {:error, {:missing_credentials, :schwab}}
    end

    test "balances only unless positions are asked for" do
      assert {:ok, [%{"securitiesAccount" => account}]} = Fake.get_account_summaries(@creds)
      assert account["currentBalances"]["buyingPower"] == 30_000
      refute Map.has_key?(account, "positions")

      assert {:ok, [%{"securitiesAccount" => expanded}]} =
               Fake.get_account_summaries(@creds, fields: "positions")

      assert [%{"instrument" => %{"symbol" => "AAPL"}}] = expanded["positions"]
    end

    test "consults FakeInjection first" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_account_summaries(@creds) == {:error, :injected}
    end
  end

  describe "get_symbol_quote/3" do
    test "needs a credential" do
      assert Fake.get_symbol_quote("AAPL", %{}) == {:error, {:missing_credentials, :schwab}}
    end

    test "answers the venue's map keyed by symbol, with Decimal prices" do
      assert {:ok, %{"AAPL" => body}} = Fake.get_symbol_quote("aapl", @creds)
      assert body["quote"]["lastPrice"] == Decimal.new("227.50")
      assert Decimal.compare(body["quote"]["bidPrice"], body["quote"]["askPrice"]) == :lt
    end

    test "a name it does not list is the venue's 404, and a pair is not pre-judged" do
      assert Fake.get_symbol_quote("ZZZZ", @creds) == {:refused, {:venue_error, 404}}
      assert Fake.get_symbol_quote("BTC-USD", @creds) == {:refused, {:venue_error, 404}}
    end

    test "is targetable by symbol through FakeInjection" do
      FakeInjection.fail_always(:schwab, "MSFT", {:error, :injected})
      assert Fake.get_symbol_quote("MSFT", @creds) == {:error, :injected}
      assert {:ok, _quote} = Fake.get_symbol_quote("AAPL", @creds)
    end
  end

  describe "get_market/3" do
    test "judges the market before the date, and both before the credential" do
      assert Fake.get_market("nasdaq", %{}) == {:error, {:unknown_market, "nasdaq"}}

      assert Fake.get_market("equity", %{}, date: "not-a-date") ==
               {:error, {:invalid_date, :date, "not-a-date"}}

      assert Fake.get_market("equity", %{}) == {:error, {:missing_credentials, :schwab}}
      assert Rest.validate_market_request("equity", date: ~D[2026-09-01]) == {:ok, "2026-09-01"}
    end

    test "a DateTime is refused as the real function refuses it" do
      date = ~U[2026-09-01 10:00:00Z]
      assert {:error, _reason} = expected = Rest.validate_market_request("equity", date: date)
      assert Fake.get_market("equity", @creds, date: date) == expected
    end

    test "equity hours are dated, with all three sessions" do
      assert {:ok, %{"equity" => %{"EQ" => hours}}} =
               Fake.get_market("equity", @creds, date: "2026-09-01")

      assert hours["date"] == "2026-09-01"
      assert hours["isOpen"] == true
      sessions = Enum.sort(Map.keys(hours["sessionHours"]))
      assert sessions == ~w(postMarket preMarket regularMarket)
    end

    test "follows :market_status, and defaults the date to the fake's instant" do
      assert {:ok, %{"option" => %{"EQO" => hours}}} =
               Fake.get_market("option", @creds, market_status: :closed)

      assert hours["isOpen"] == false
      assert hours["date"] == "2026-08-31"
    end

    test "a market the specification shows no example for is the venue's 404, not invented" do
      assert Fake.get_market("forex", @creds) == {:refused, {:venue_error, 404}}
    end
  end

  describe "get_instrument/3" do
    test "needs a credential" do
      assert Fake.get_instrument("037833100", %{}) == {:error, {:missing_credentials, :schwab}}
    end

    test "the vendor example CUSIP is AAPL; any other is the venue's 404" do
      assert {:ok, %{"symbol" => "AAPL", "cusip" => "037833100"}} =
               Fake.get_instrument("037833100", @creds)

      assert Fake.get_instrument("000000000", @creds) == {:refused, {:venue_error, 404}}
    end

    test "a non-binary or blank CUSIP is refused by name, on the Fake and the real facade alike" do
      refusal = {:error, {:invalid_path_segment, :schwab}}

      for bad <- [37_833_100, nil, ""] do
        assert Fake.get_instrument(bad, @creds) == refusal
        assert Schwab.get_instrument(bad, @creds) == refusal
      end
    end
  end

  describe "get_user_preference/2" do
    test "needs a credential" do
      assert Fake.get_user_preference(%{}) == {:error, {:missing_credentials, :schwab}}
    end

    test "answers the account and streamer blocks" do
      assert {:ok, %{"accounts" => [account], "streamerInfo" => [streamer]}} =
               Fake.get_user_preference(@creds)

      assert account["accountNumber"] == "123456789"
      assert String.starts_with?(streamer["streamerSocketUrl"], "wss://")
    end

    test "consults FakeInjection first" do
      FakeInjection.fail_always(:schwab, {:error, :injected})
      assert Fake.get_user_preference(@creds) == {:error, :injected}
    end
  end

  test "bypass_credentials/1 lets a wiring-only test skip the access token on the reads" do
    FakeInjection.bypass_credentials(:schwab)

    assert {:ok, _accounts} = Fake.get_account_summaries(%{})
    assert {:ok, _preference} = Fake.get_user_preference(%{})
  end
end
