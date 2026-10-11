defmodule DpExchange.Schwab.BoundedTextTest do
  @moduledoc """
  Venue-supplied text is bounded before it enters an error tuple, a notice or telemetry.

  A proxy's HTML error page or a hostile reply must not become megabytes in every caller's
  tuple, and a short message must come out exactly as the venue sent it.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias DpExchange.Core.Config
  alias DpExchange.Schwab.{Auth, Bound, Rest, StreamerProtocol}

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @creds %{access_token: "at-1"}

  @refresh_creds %{
    client_id: "id",
    client_secret: "secret",
    access_token: "at",
    refresh_token: "rt"
  }

  defp responding(body, status) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  defp price(body, status) do
    Rest.get_price("AAPL", @creds, plug: responding(body, status), retry_attempts: 0)
  end

  describe "Bound.text/1" do
    test "a short message is unchanged" do
      assert Bound.text("Order validation failed") == "Order validation failed"
      assert Bound.text(String.duplicate("a", 2_048)) == String.duplicate("a", 2_048)
    end

    test "nil stays nil" do
      assert Bound.text(nil) == nil
    end

    test "a long binary is cut to the byte limit and marked with its full size" do
      long = String.duplicate("a", 10_000)
      bounded = Bound.text(long)

      assert String.starts_with?(bounded, String.duplicate("a", 2_048))
      assert String.ends_with?(bounded, "(10000 bytes)")
      assert byte_size(bounded) < 2_100
    end

    test "the cut lands on a UTF-8 boundary" do
      # Three-byte characters: 2_048 is not a multiple of 3, so a raw cut splits one.
      long = String.duplicate("€", 1_000)
      bounded = Bound.text(long)

      assert String.valid?(bounded)
      assert String.ends_with?(bounded, "(3000 bytes)")
    end

    test "a non-binary term is inspected with a limit" do
      bounded = Bound.text(%{"k" => String.duplicate("x", 10_000)})

      assert is_binary(bounded)
      assert byte_size(bounded) < 2_300
    end
  end

  describe "Bound.reason/1" do
    test "a huge reason term is bounded" do
      reason = {:error, String.duplicate("y", 100_000), Enum.to_list(1..1_000)}

      assert byte_size(Bound.reason(reason)) < 1_500
    end

    test "a small reason is rendered whole" do
      assert Bound.reason(:closed) == ":closed"
    end
  end

  describe "Rest.refusal/2 bounds the venue's detail" do
    test "an oversized errors detail is cut and marked" do
      body = %{"errors" => [%{"detail" => String.duplicate("z", 50_000)}]}

      assert {:refused, {:venue_error, 400, detail}} = price(body, 400)
      assert byte_size(detail) < 2_100
      assert String.ends_with?(detail, "(50000 bytes)")
    end

    test "an oversized message is cut" do
      body = %{"message" => String.duplicate("m", 50_000)}

      assert {:refused, {:venue_error, 404, detail}} = price(body, 404)
      assert byte_size(detail) < 2_100
    end

    test "an oversized error_description is cut" do
      body = %{"error_description" => String.duplicate("d", 50_000)}

      assert {:refused, {:venue_error, 401, detail}} = price(body, 401)
      assert byte_size(detail) < 2_100
    end

    test "a non-string errors detail becomes bounded text, not a raw term" do
      body = %{"errors" => [%{"detail" => %{"nested" => String.duplicate("n", 50_000)}}]}

      assert {:refused, {:venue_error, 400, detail}} = price(body, 400)
      assert is_binary(detail)
      assert byte_size(detail) < 2_300
    end

    test "a short detail is unchanged" do
      body = %{"errors" => [%{"detail" => "Insufficient buying power"}]}

      assert {:refused, {:venue_error, 400, "Insufficient buying power"}} = price(body, 400)
    end
  end

  describe "Auth.refresh/2 bounds the venue's detail" do
    test "an oversized error_description is cut" do
      body = %{"error" => "invalid_grant", "error_description" => String.duplicate("e", 50_000)}

      assert {:refused, {:reauthorization_required, 400, detail}} =
               Auth.refresh(@refresh_creds, plug: responding(body, 400), retry_attempts: 0)

      assert byte_size(detail) < 2_100
      assert String.ends_with?(detail, "(50000 bytes)")
    end
  end

  describe "StreamerProtocol.failure_message/1" do
    test "an oversized msg is cut, a short one unchanged" do
      long = %{"content" => %{"msg" => String.duplicate("s", 50_000)}}

      assert byte_size(StreamerProtocol.failure_message(long)) < 2_100
      assert StreamerProtocol.failure_message(%{"content" => %{"msg" => "denied"}}) == "denied"
    end
  end
end
