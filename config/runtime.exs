import Config

# Runtime configuration. Evaluated on every boot, after compilation.
#
# THIS IS THE ONLY FILE THAT MAY CALL `System.get_env/1` (§7.7). Every read
# carries a dev/test fallback literal so a missing var degrades to a working
# development default rather than a boot crash:
#
#     config :dp_exchange_gemini,
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
# `dp_exchange_gemini` currently reads nothing. It is a contract library: it
# opens no sockets, holds no credentials, and takes its one configurable seam
# (`:rate_limit_module`, D5) from the CONSUMER's application environment at
# call time, never from here.
