import Config

# Runtime configuration. Evaluated on every boot, after compilation.
#
# THIS IS THE ONLY FILE THAT MAY CALL `System.get_env/1` (§7.7). Every read
# carries a dev/test fallback literal so a missing var degrades to a working
# development default rather than a boot crash:
#
#     config :dp_exchange_schwab,
#       some_key: System.get_env("SOME_KEY") || "dev-only-some-key"
#
# Adding a var is a five-step lifecycle — all five or none:
#
#   1. the read here, with a fallback
#   2. a placeholder line in `.env.sample`
#   3. the real value in your local, gitignored `.env.*`
#   4. tell CI to set it
#   5. tell the deploy platform to set it
#
# `dp_exchange_schwab` currently reads nothing, and that is not because it does
# nothing: it opens the venue's Streamer socket and signs every request. It holds
# no credentials — they are passed per call by the host and never stored here
# (§6.0) — and it takes its configurable seams (`:rate_limit_module`,
# `:http_adapter`, D5) from the CONSUMER's application environment at call time,
# never from here.
