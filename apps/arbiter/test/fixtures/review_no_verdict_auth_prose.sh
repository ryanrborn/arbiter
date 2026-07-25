#!/bin/sh
# Fixture: a reviewer that completes CLEANLY (exit 0) but never prints a
# parseable VERDICT line. Its review prose happens to discuss auth/quota code
# and mentions "/login" and "retry after backoff" — ordinary review language,
# not an infrastructure failure. Regression fixture for bd-b2glhm round 2: the
# infra-failure classifier must never run on an exit-0 subprocess (other than
# the harness-emitted :stream_schema_drift marker), or this gets misclassified
# as an auth-expiry crash and skips the verdict re-prompt entirely.
echo "reviewing the diff..."
echo "This PR touches CredentialWatchdog; on 401/unauthorized it should redirect to /login."
echo "Also consider whether the rate limiter should retry after backoff."
echo "(no VERDICT line emitted)"
exit 0
