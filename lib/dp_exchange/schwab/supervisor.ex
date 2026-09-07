defmodule DpExchange.Schwab.Supervisor do
  @moduledoc """
  This venue's process tree — internal.

  A limiter and a feed, exactly as every other venue in the family. That sameness is the
  point: a consumer's supervision tree looks identical whichever venue it holds — and it
  stays identical whichever route the feed takes, since `Feed` chooses between the venue's
  Streamer and its own REST poll behind this tree rather than in front of it.

  ## The limiter is configured, not declared

  Every other venue in the family takes its limits from `capabilities/0`. This one cannot:
  Schwab's documented ceiling is `0..120` order writes per minute **per account**, set
  **per application at registration**, so there is no venue constant to read. A number
  baked in here would be a claim about somebody else's registration.

  So the limits come from options, and the default is deliberately generous for reads —
  which the venue documents as unthrottled — while a host that places orders should pass
  `:order_limit_per_minute` matching what its own app was registered with. Zero is a legal
  registration value, and a host with it should pass `0` rather than discover the ceiling
  by being refused.

  ## Omitting `:order_limit_per_minute` is not the same question as omitting reads

  This used to default the missing option to `reads` — generous, because reads are
  unthrottled, and therefore **exactly the wrong number to reuse for writes**: a host that
  said nothing about its own registration got a ceiling as high as this venue's own
  documented maximum (`0..120`), which is an optimistic guess about somebody else's
  registration dressed up as a courtesy default. That was a defect (found by a
  documentation-accuracy sweep, 2026-09-06): this module's own moduledoc already said "a
  number baked in here would be a claim about somebody else's registration," and the code
  baked one in anyway for the one case — silence — where the claim is least justified.

  The fix does not invent a *different* number to fill the same hole. A registration this
  package was never told about is not usefully approximated by any single digit, optimistic
  or not — the honest content of "the host said nothing" is that this package does not
  know whether the host can write **any** orders, so `@default_order_limit` is `0`, and it
  is documented as exactly that: not a measured ceiling, not the venue's default (the venue
  has none), but this package's own refusal to assume a registration exists until told
  otherwise. A host that can place orders states its own ceiling; one that never intends to
  place any pays nothing for leaving it out, because the read limiter it does use is
  unaffected.
  """

  use Supervisor

  alias DpExchange.Core.DefaultRateLimiter
  alias DpExchange.Schwab.Feed

  # Reads are documented as unthrottled. This is a courtesy ceiling rather than a measured
  # one, and it is not a claim about the venue — it exists so a runaway poll cannot become
  # a self-inflicted incident.
  @default_read_limit 120

  # **Not a venue fact and not a guess at one.** Schwab's own ceiling for order writes is
  # `0..120` per minute per account, set per application at registration, and this package
  # holds no consumer's registration. Zero is the one number in that range that is never
  # wrong to assume when nothing was said: a host actually registered higher loses nothing
  # it needed by default (it states its own ceiling via `:order_limit_per_minute` and gets
  # it), while a host silently defaulted to any higher number would have been allowed to
  # write orders against a permission this package never confirmed it has.
  @default_order_limit 0

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = [
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits(opts)},
      {Feed,
       opts |> Keyword.put(:name, feed_name(opts)) |> Keyword.put(:limiter, limiter_name(opts))}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The limiter this venue meters against."
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts), do: Keyword.get(opts, :limiter, DpExchange.Schwab.RateLimiter)

  @doc "This venue's feed process."
  @spec feed_name(keyword()) :: atom()
  def feed_name(opts), do: Keyword.get(opts, :feed, Feed)

  @doc """
  The limits this tree meters with.

  `:read_limit_per_minute` defaults to #{@default_read_limit}. `:order_limit_per_minute`
  defaults to #{@default_order_limit} — not a venue fact, since the venue has none to
  default to, but this package's own refusal to assume a registration it was never told
  about. A host that can place orders passes its own ceiling; see the moduledoc.
  """
  @spec limits(keyword()) :: map()
  def limits(opts) do
    reads = Keyword.get(opts, :read_limit_per_minute, @default_read_limit)
    orders = Keyword.get(opts, :order_limit_per_minute, @default_order_limit)

    %{
      default: %{limit: reads, per_ms: 60_000, burst: reads},
      schwab: %{limit: reads, per_ms: 60_000, burst: reads},
      # `scope: :account` because that is what Schwab counts against, and a limiter keyed
      # by credential would silently over-permit a host running several accounts through
      # one registration.
      #
      # `max(orders, 1)` is not a floor on the DECLARATION — zero is legal there and means
      # a registration granted no order throughput. It is a floor on the GCRA arithmetic,
      # which divides by the rate. A host registered at zero should not be placing orders
      # at all, and `capabilities/0` is where that is said.
      schwab_orders: %{
        limit: max(orders, 1),
        per_ms: 60_000,
        burst: max(orders, 1),
        scope: :account
      }
    }
  end
end
