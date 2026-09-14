# Tier 2 hits Schwab's live public API. Excluded by default and run by hand: a venue
# that sees a package polling it on a timer will rate-limit or block.
ExUnit.start(exclude: [:tier2])

# Warm the plug-backed request path before any test is timed against it.
#
# Measured 2026-09-14: the FIRST `Req` request in a VM takes ~108 ms to reach its plug,
# and every one after it takes ~0 ms — module loading and pool setup, paid once. Any test
# whose budget is smaller than that loses a race it never meant to run, and which test pays
# the cost depends on the seed, so the failure moves around rather than reproducing.
#
# It was not hypothetical here. `feed_test.exs`'s two wedged-bootstrap tests asked
# for `route_bootstrap_timeout_ms:` of 100 and 300, and BOTH failed when run on
# their own — the timeout fired before the plug was ever reached — while passing in a
# full run because something else had already paid the 108 ms. `mix test path:line`, which
# is what you run while working on a test, was the one way to see it.
#
# Warming rather than inflating every such budget keeps the budgets honest: one is meant to
# say "this bootstrap is given three tenths of a second", not to out-wait a one-off start-up
# cost. The two fixes were measured separately and neither was sufficient alone. Warming
# with the smaller budget still left it failing two runs in three. Raising it to 300 without
# warming left BOTH tests intermittent — two failures in four, and one in four. Warming plus
# 300 ms is clean: thirteen isolated runs of one and eight of the other, no failures.
_warmup =
  Req.get("https://warmup.invalid/",
    plug: fn conn -> Plug.Conn.resp(conn, 200, "") end,
    retry: false
  )
