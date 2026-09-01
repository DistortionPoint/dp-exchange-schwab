defmodule DpExchange.Schwab.StreamerInfo do
  @moduledoc """
  What a caller needs before it can open the Streamer — and the five values it cannot guess.

  ## The socket cannot be reached without this call

  `GET /trader/v1/userPreference` is the Streamer's bootstrap. It returns
  `streamerInfo.streamerSocketUrl`, and **that URL is not a constant**: it is issued per
  account, so hardcoding one from another account's response would connect the wrong
  session or none at all.

  The same response carries the four identifiers the `LOGIN` command requires —
  `schwabClientCustomerId`, `schwabClientCorrelId`, `schwabClientChannel` and
  `schwabClientFunctionId`. None is derivable from a credential, an account number, or
  anything else this package holds. **The venue's own error notes say a client that
  modifies `SchwabClientCustomerId` or `SchwabClientCorrelId` after logging in loses the
  connection**, which is why these are fetched once and carried rather than rebuilt.

  ## Why this is its own module

  Because it is the piece whose absence made the venue look like it had no streaming API at
  all. `GET /userPreference` is in the Accounts and Trading specification, `streamerInfo` is
  in its response schema, and neither says the word "streaming" — so a reader auditing the
  OpenAPI documents for a socket found nothing and concluded there was none.

  The Streamer is documented in the *prose* beside the specifications, committed at
  `docs/reference/schwab/documentation/market-data-production.txt`. Keeping the bootstrap
  visible here, named for what it is, is how that mistake stops being repeatable.
  """

  @enforce_keys [:socket_url, :customer_id, :correl_id, :channel, :function_id]
  defstruct [:socket_url, :customer_id, :correl_id, :channel, :function_id]

  @type t :: %__MODULE__{
          socket_url: String.t(),
          customer_id: String.t(),
          correl_id: String.t(),
          channel: String.t(),
          function_id: String.t()
        }

  @doc """
  Reads a `t:t/0` out of the venue's `/userPreference` response.

  **Every field is required and a missing one is an error**, not a `nil` carried forward.
  A `LOGIN` sent without `SchwabClientCorrelId` is refused by the venue with a message
  about the connection rather than about the field, and a package that let the `nil` through
  would surface that as a connection fault.
  """
  @spec from_user_preference(map()) :: {:ok, t()} | {:error, term()}
  def from_user_preference(%{"streamerInfo" => [info | _rest]}), do: build(info)
  def from_user_preference(%{"streamerInfo" => %{} = info}), do: build(info)
  def from_user_preference(_body), do: {:error, :no_streamer_info}

  defp build(%{} = info) do
    fields = [
      socket_url: info["streamerSocketUrl"],
      customer_id: info["schwabClientCustomerId"],
      correl_id: info["schwabClientCorrelId"],
      channel: info["schwabClientChannel"],
      function_id: info["schwabClientFunctionId"]
    ]

    case Enum.filter(fields, fn {_key, value} -> is_nil(value) or value == "" end) do
      [] -> {:ok, struct!(__MODULE__, fields)}
      missing -> {:error, {:incomplete_streamer_info, Enum.map(missing, &elem(&1, 0))}}
    end
  end

  defp build(_info), do: {:error, :no_streamer_info}
end
