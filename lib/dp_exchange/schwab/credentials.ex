defmodule DpExchange.Schwab.Credentials do
  @moduledoc """
  Wraps the OAuth credential set (`access_token`, `refresh_token`, `client_id`,
  `client_secret`) so it can sit in a `GenServer`'s state without printing in full the
  moment that process crashes.

  ## The incident this closes

  `Feed` holds `state.credentials` for its entire lifetime — a poll or a stream
  bootstrap signs with it on every tick, and `update_credentials/2` replaces it in place
  after a refresh rather than restarting the process. `Socket` holds `state.access_token`
  the same way, for the `LOGIN` frame it sends on every (re)connect. OTP's default crash
  report prints a process's state in full on termination, and a **plain map or bare
  string** field prints in full — the refresh token and client secret included, and
  those are exactly the values whose rotation this package's moduledoc calls
  "destructive": a leaked refresh token is not a credential that can simply be reissued,
  it is one that has already been spent by the time anyone reads the log.

  A struct whose `Inspect` is derived with `except:` naming every field closes this:
  `Kernel.inspect/1` — which both the crash-report formatter and a `FunctionClauseError`'s
  printed argument list go through — honours a struct's `Inspect` protocol even nested
  inside an otherwise-plain state map. Wrapping once, at the point credentials enter a
  long-lived process, and letting the struct itself flow into every downstream call keeps
  `Auth.headers/2` (`%{access_token: token} = credentials`) and `Auth.refresh/2` working
  unchanged — a struct is a map.

  ## Why `Feed` no longer stores the raw `opts` it was started with

  `Feed.init/1` used to keep BOTH `state.credentials` and `state.opts` — the latter the
  complete keyword list `init/1` received, `:credentials` entry included. That was a
  second, unwrapped copy of the same secret sitting in the same state map. `state.opts`
  never needed the credential itself (`Keyword.take/2` and `DpExchange.Core.Config.opt/3`
  calls against it only ever read `:url`, `:interval_ms`, `:start_delay_ms` and similar),
  so it is now
  stored with `:credentials` stripped rather than wrapped-and-duplicated.
  """

  @derive {Inspect, except: [:access_token, :refresh_token, :client_id, :client_secret]}
  defstruct [:access_token, :refresh_token, :client_id, :client_secret, :expires_at]

  @type t :: %__MODULE__{
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          client_id: String.t() | nil,
          client_secret: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc """
  Wraps a raw credentials map for storage in process state.

  Any map is struct-ified with `Kernel.struct/2`, which ignores keys the struct does not
  declare rather than raising — `Auth`'s own `credentials()` type is deliberately open
  (`optional(any()) => any()`), so a caller-supplied extra key was never guaranteed to
  mean anything here and this preserves that tolerance.
  """
  @spec wrap(map()) :: t()
  def wrap(%__MODULE__{} = credentials), do: credentials
  def wrap(credentials) when is_map(credentials), do: struct(__MODULE__, credentials)

  @doc """
  Wraps a bare access-token string, for `Socket`'s state — see the moduledoc. The other
  fields stay `nil`; `Socket` only ever reads `access_token` back out.
  """
  @spec wrap_token(String.t()) :: t()
  def wrap_token(access_token) when is_binary(access_token),
    do: %__MODULE__{access_token: access_token}
end
