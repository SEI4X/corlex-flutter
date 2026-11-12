#!/bin/sh
# The same complete production C/Swift closure exercises the protected channel adapter.
set -eu
exec "$(dirname "$0")/test-crash.sh" channel
