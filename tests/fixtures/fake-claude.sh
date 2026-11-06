#!/bin/sh
# Stands in for `claude` in the launcher tests: prints its cwd and argv,
# then echoes its input until killed.
echo "FAKE-CLAUDE cwd=$(pwd)"
for a in "$@"; do echo "ARG[$a]"; done
echo "FAKE-CLAUDE ready"
exec cat
