#!/bin/sh
# Exercise the installed package from outside its source tree.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/memcached-package.XXXXXX")
trap 'rm -rf "$build"' EXIT
ZAP_CACHE="$build/cache"
export ZAP_CACHE
unset ZAP_ZENV
version=$(sed -n 's/^version = "\([^"]*\)"$/\1/p' "$here/zap.toml")

(
    cd "$here"
    zap publish --dry-run
    zap publish --registry "file://$build/index"
)

for kind in path registry; do
    consumer="$build/$kind-consumer"
    mkdir -p "$consumer/tests"
    cat > "$consumer/zap.toml" <<'MANIFEST'
[package]
name = "memcached_consumer"
version = "0.0.0"
MANIFEST
    cp "$here/tests/package_consumer.zap" "$consumer/tests/package_consumer.zap"
    (
        cd "$consumer"
        if [ "$kind" = path ]; then
            zap add memcached --path "$here"
        else
            cat >> zap.toml <<MANIFEST
[registries.fixture]
index = "file://$build/index"
[dependencies]
memcached = { registry = "memcached", version = "$version", index = "fixture" }
MANIFEST
        fi
        zap zenv create --no-venv
        ZAP_ZENV="$consumer/zenv"
        export ZAP_ZENV
        test -f zap.lock
        test -f "$ZAP_ZENV/pkg/memcached/src/memcached.zap"
        timeout -k 5s 60s zap test tests/package_consumer.zap
        echo "$kind consumer: PASS"
    )
done
