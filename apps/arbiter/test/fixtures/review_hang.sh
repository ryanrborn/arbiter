#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker that NEVER produces a verdict — every
# pass hangs past the ReviewGate's per-pass timeout. Unlike
# `review_timeout_retry.sh` (which converges on its retry), this one keeps
# hanging, so the gate exhausts its timeout-retry budget and escalates as
# timed-out. Used to exercise bd-216r3e: the timeout must escalate as
# INCONCLUSIVE (no re-dispatch loop), and each pass must re-resolve its timeout
# from live workspace config.
echo "hanging pass: no verdict will be produced..."
sleep 60
exit 0
