# Dialyzer warning filters for the whole umbrella (see `dialyzer/0` in
# mix.exs, which points every app here).
#
# `list_unused_filters: true` is set alongside it, so a filter that stops
# matching FAILS the run rather than lingering. That is deliberate: a
# suppression file nobody prunes is how a real warning eventually gets
# masked by a stale entry someone added for an unrelated reason.
#
# Entries may be:
#
#     {"lib/arbiter/some_module.ex"}                      # whole file
#     {"lib/arbiter/some_module.ex", :unknown_function}   # file + warning type
#     {"lib/arbiter/some_module.ex", :call, 42}           # file + type + line
#     ~r/regex against the formatted warning/
#
# Add one only with a comment saying which warning it silences and why the
# code is correct as written.
[]
