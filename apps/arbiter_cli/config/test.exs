import Config

config :logger, level: :warning

# The :arbiter app boots in this VM too (test-only dep), but this app has its
# own config tree (`config_path: "config/config.exs"` in mix.exs) so the
# root's phase-10 kill switches never apply here. Repeat them, or this VM's
# `Heartbeat` writes to the host-global `/run/user/<uid>/arbiter/heartbeat`
# on every run (bd-3qkbch, phase 10).
config :arbiter, :sessions_heartbeat, enabled: false
config :arbiter, :sessions_idle_reaper, enabled: false
config :arbiter, :sessions_orphan_reaper, enabled: false
