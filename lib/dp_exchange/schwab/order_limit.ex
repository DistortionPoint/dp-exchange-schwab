defmodule DpExchange.Schwab.OrderLimit do
  @moduledoc """
  Whether this tree's order ceiling was **stated or defaulted** — one fact, held for the
  life of the supervision tree because nothing else in it is positioned to answer this
  later.

  ## Why this needs its own process

  `DpExchange.Schwab.Supervisor.limits/1` computes the *number* the rate limiter meters order writes
  against, and it does that once, at `start_link/1`, from options a much later call to
  `DpExchange.Schwab.place_order/3` (or `replace_order/4`, `cancel_order/3`) does not
  repeat — there is no reason for a caller to pass `:order_limit_per_minute` again on
  every order, and nothing in the facade expects it there. So the fact this module holds
  — was the option ever passed, distinct from what number it resolved to — has nowhere
  else to live: `DpExchange.Core.Config`'s process-scoped overrides deliberately do not
  survive to a process that never called through the one that set them, and an order is
  routinely placed from a process that never started this tree at all — a controller, a
  job, a health check. A supervised, named process is what OTP has for exactly this: a
  fact that outlives the call that produced it and answers any caller that asks, later.

  ## Not started is not "not declared"

  A consumer who never supervises this module at all — calling `Rest.place_order/4`
  directly with their own `:limiter`, which this package has always allowed — gets no
  opinion from this module, not a refusal. `status/1` distinguishes the two: `{:error,
  :not_started}` when nothing is running under `name`, a real `t:t/0` when something is.
  The facade only refuses on the second case. Collapsing "I don't know" into "refused"
  would make every consumer who bypasses `Supervisor` start failing a check it never
  opted into — several of this package's own tests among them.
  """

  alias DpExchange.Schwab.Supervisor, as: SchwabSupervisor

  @typedoc "Whether `:order_limit_per_minute` was passed, and the ceiling if it was."
  @type t :: %{declared?: boolean(), limit: non_neg_integer()}

  @doc "Starts, holding `t:t/0` for as long as the process named `opts[:name]` lives."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    state = %{declared?: Keyword.fetch!(opts, :declared?), limit: Keyword.fetch!(opts, :limit)}
    Agent.start_link(fn -> state end, name: name)
  end

  @doc """
  The fact `name` holds, or `{:error, :not_started}` when nothing is running under it —
  see the moduledoc for why the two are not the same as "not declared".
  """
  @spec status(GenServer.server()) :: t() | {:error, :not_started}
  def status(name) do
    Agent.get(name, & &1)
  catch
    :exit, _reason -> {:error, :not_started}
  end

  @doc """
  Whether an order write may proceed under the tree named by `opts`.

  See `DpExchange.Schwab.Supervisor`'s "A silent 0 is still the wrong fix" section.
  `{:error, :not_started}` means this consumer never supervised `OrderLimit` at all —
  bypassing `Supervisor` entirely with a `:limiter` of its own, which this package has
  always allowed — and gets no opinion here, not a refusal: collapsing "I was never asked"
  into "refused" would fail every consumer who does that. `declared?: false` means a tree
  WAS started through `Supervisor` and specifically never told an order ceiling, which every
  order write refuses (`{:error, :order_limit_not_declared}`) rather than let masquerade as
  the venue's own throttling. A declared `0` is `{:error, :order_limit_zero}`: found
  2026-10-10 by reading the path, it reached the limiter through `max(orders, 1)` and was
  permitted one write a minute though the registration granted none.
  """
  @spec ensure_declared(keyword()) ::
          :ok | {:error, :order_limit_not_declared | :order_limit_zero}
  def ensure_declared(opts) do
    case status(SchwabSupervisor.order_limit_name(opts)) do
      {:error, :not_started} -> :ok
      %{declared?: false} -> {:error, :order_limit_not_declared}
      %{declared?: true, limit: 0} -> {:error, :order_limit_zero}
      %{declared?: true} -> :ok
    end
  end

  @doc "Child spec, so `Supervisor` supervises this the same way it supervises any child."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end
end
