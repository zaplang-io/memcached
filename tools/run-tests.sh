#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/memcached-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT

# Stage one module so the suite can exercise private protocol and socket helpers.
{
    cat "$here/src/memcached.zap"
    printf '\n'
    cat "$here/tests/memcached_test.zap"
} > "$build/memcached_test.zap"
zap test "$build/memcached_test.zap" "$@"
