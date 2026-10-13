#!/usr/bin/env bash
# Smoke test of the image: runs it with smoke-test.conf and checks that mod_qos,
# mod_maxminddb, mod_proxy_uwsgi, mod_ratelimit and mod_ssl work.
#
# Usage: tests/smoke-test.sh [image]
set -euo pipefail

IMAGE="${1:-arquivo/arquivo-apache-httpd:test}"
# MaxMind test databases, https://github.com/maxmind/MaxMind-DB/tree/main/test-data
MAXMIND_DB_COMMIT=6a690a705bc6962c0025a32e94a8f0dc8f86418c

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="$(mktemp -d)"
CONTAINER="arquivo-apache-httpd-smoke-test-$$"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

failures=0
check() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "ok     - $description"
    else
        echo "not ok - $description: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

curl -fsSLo "$WORK_DIR/GeoIP2-Country-Test.mmdb" \
    "https://raw.githubusercontent.com/maxmind/MaxMind-DB/${MAXMIND_DB_COMMIT}/test-data/GeoIP2-Country-Test.mmdb"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -keyout "$WORK_DIR/smoke-test.key" -out "$WORK_DIR/smoke-test.crt" 2>/dev/null
head -c 4096 /dev/zero > "$WORK_DIR/ratelimit"
chmod a+r "$WORK_DIR"/*

docker run -d --name "$CONTAINER" -p 127.0.0.1::80 -p 127.0.0.1::443 \
    -v "$TESTS_DIR/smoke-test.conf:/usr/local/apache2/conf.d/smoke-test.conf:ro" \
    -v "$WORK_DIR/GeoIP2-Country-Test.mmdb:/usr/share/GeoIP/GeoIP2-Country-Test.mmdb:ro" \
    -v "$WORK_DIR/smoke-test.crt:/usr/local/apache2/conf/smoke-test.crt:ro" \
    -v "$WORK_DIR/smoke-test.key:/usr/local/apache2/conf/smoke-test.key:ro" \
    -v "$WORK_DIR/ratelimit:/usr/local/apache2/htdocs/ratelimit:ro" \
    "$IMAGE" >/dev/null

sleep 2
if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != true ]]; then
    echo "httpd did not start:"
    docker logs "$CONTAINER"
    exit 1
fi

HTTP="http://$(docker port "$CONTAINER" 80/tcp)"
HTTPS="https://$(docker port "$CONTAINER" 443/tcp)"

for _ in $(seq 30); do
    curl -fso /dev/null "$HTTP/" && break
    sleep 1
done

modules="$(docker exec "$CONTAINER" httpd -M 2>&1)"
for module in qos_module maxminddb_module ssl_module proxy_uwsgi_module ratelimit_module; do
    check "$module is loaded" yes "$(grep -q " $module " <<<"$modules" && echo yes || echo no)"
done

check "serves the default page" 200 "$(curl -so /dev/null -w '%{http_code}' "$HTTP/")"

check "mod_maxminddb geolocates 81.2.69.160" GB \
    "$(curl -s -D - -o /dev/null -H 'X-Forwarded-For: 81.2.69.160' "$HTTP/" | tr -d '\r' | sed -n 's/^X-Country-Code: //Ip')"

check "mod_proxy_uwsgi proxies to the uwsgi backend" 503 "$(curl -so /dev/null -w '%{http_code}' "$HTTP/uwsgi")"

seconds="$(curl -so /dev/null -w '%{time_total}' "$HTTP/ratelimit")"
check "mod_ratelimit throttles 4 KiB at 1 KiB/s (took ${seconds}s)" yes \
    "$(awk -v s="$seconds" 'BEGIN { print (s >= 2 ? "yes" : "no") }')"

check "mod_ssl serves HTTPS" 200 "$(curl -kso /dev/null -w '%{http_code}' "$HTTPS/")"

# Last, as mod_qos then denies every request of the client: the request that reaches the
# QS_ClientEventLimitCount limit (3, counting itself) and all of the following ones
statuses=""
for _ in 1 2 3 4; do
    statuses+="$(curl -so /dev/null -w '%{http_code}' "$HTTP/qos") "
done
check "mod_qos limits the client on the 3rd request" "404 404 429 429" "${statuses% }"
check "mod_qos keeps the client limited" 429 "$(curl -so /dev/null -w '%{http_code}' "$HTTP/")"

if ((failures > 0)); then
    echo "$failures check(s) failed, httpd logs:"
    docker logs "$CONTAINER"
    exit 1
fi
