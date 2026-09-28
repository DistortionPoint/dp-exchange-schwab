# Tier 2 hits Schwab's live public API. Excluded by default and run by hand: a venue
# that sees a package polling it on a timer will rate-limit or block.
ExUnit.start(exclude: [:tier2])

# **Tier 1 never reaches a venue, and this makes that a fact rather than a convention.** A
# request that brings no `:plug` of its own gets this one, which refuses it and names the
# host. Measured 2026-09-27: a tier-1 run opened a real connection to a venue, from a test
# that had forgotten its stub. Nothing failed, because the venue answered. Not installed
# for a tier-2 run (`mix test --only tier2`), which is the one place the live API is meant.
tier2_run? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(&(&1 == :tier2 or match?({:tier2, _value}, &1)))

require Logger

unless tier2_run? do
  Req.default_options(
    plug: fn conn ->
      message =
        "NETWORK-GUARD: a tier-1 test sent #{conn.method} #{conn.host}#{conn.request_path} " <>
          "to the network. Give the call its own `plug:`."

      Logger.error(message)
      raise message
    end
  )
end
