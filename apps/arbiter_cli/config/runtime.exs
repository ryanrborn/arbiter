import Config

# The CLI reads ARB_HOST / ARB_WORKSPACE / ARB_TOKEN directly via System.get_env/2
# at call-site (see ArbiterCli.Client and ArbiterCli.Workspace). There is no
# server-side config (SECRET_KEY_BASE, DATABASE_PATH, endpoint bind config) here —
# those belong to the arbiter_web release, not the escript.
