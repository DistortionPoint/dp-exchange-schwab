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

  @doc "Child spec, so `Supervisor` supervises this the same way it supervises any child."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end
end
