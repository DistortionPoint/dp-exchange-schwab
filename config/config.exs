import Config

# Build-time configuration. Evaluated during `mix compile`, so the values are
# baked into the artifact.
#
# MUST NOT read the environment. `System.get_env/1` belongs in `runtime.exs`
# and nowhere else (§7.7). This file, and the three it imports, are static.
#
# Nothing here ships. `config/` is absent from `mix.exs`'s `files:`, so it
# governs this package's own dev and test only — a consumer configures
# `:dp_exchange_gemini` from their own config.

import_config "#{config_env()}.exs"
