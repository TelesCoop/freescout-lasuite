#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-freescout-custom}"
APP_URL=http://localhost:8080
APP_CONTAINER=freescout-e2e-app
DB_CONTAINER=freescout-e2e-db
NETWORK=freescout-e2e
VOLUME=freescout-e2e-data
ADMIN_EMAIL=admin@example.com
# Spaces, '#' and '&' exercise the quoting of values written to .env.
ADMIN_PASS='Admin pass #1 & more'
DB_PASS='db pass #1 & more'
COOKIE_JAR=$(mktemp)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

on_exit() {
    local exit_status=$?
    if [ "${exit_status}" -ne 0 ] && docker inspect "${APP_CONTAINER}" >/dev/null 2>&1; then
        echo "=== ${APP_CONTAINER} logs ===" >&2
        docker logs "${APP_CONTAINER}" >&2
    fi
    docker rm -f "${APP_CONTAINER}" "${DB_CONTAINER}" >/dev/null 2>&1 || true
    docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
    docker network rm "${NETWORK}" >/dev/null 2>&1 || true
    rm -f "${COOKIE_JAR}"
}
trap on_exit EXIT

wait_until() {
    local description="$1"
    shift
    for _ in $(seq 1 60); do
        if "$@"; then
            return 0
        fi
        sleep 5
    done
    fail "timed out waiting for ${description}"
}

database_ready() {
    docker exec "${DB_CONTAINER}" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1
}

app_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "${APP_CONTAINER}")" = true ]
}

login_page_ready() {
    app_running || fail "${APP_CONTAINER} exited"
    curl -fs -o /dev/null "${APP_URL}/login"
}

start_app() {
    docker run -d --name "${APP_CONTAINER}" --network "${NETWORK}" \
        -p 8080:8080 \
        --cap-drop ALL \
        --security-opt no-new-privileges \
        -v "${VOLUME}:/data" \
        -e APP_URL="${APP_URL}" \
        -e DB_TYPE=mariadb \
        -e DB_HOST="${DB_CONTAINER}" \
        -e DB_NAME=freescout \
        -e DB_USER=freescout \
        -e DB_PASS="${DB_PASS}" \
        -e ADMIN_EMAIL="${ADMIN_EMAIL}" \
        -e ADMIN_PASS="${ADMIN_PASS}" \
        "${IMAGE}" >/dev/null
    wait_until "the login page" login_page_ready
}

assert_admin_can_log_in() {
    local login_page csrf_token dashboard_status
    rm -f "${COOKIE_JAR}"
    login_page=$(curl -fsS -c "${COOKIE_JAR}" "${APP_URL}/login")
    grep -q 'name="password"' <<<"${login_page}" || fail "login form not rendered"
    csrf_token=$(grep -o -m1 'name="_token" value="[^"]*"' <<<"${login_page}" | cut -d'"' -f4)
    [ -n "${csrf_token}" ] || fail "CSRF token missing from the login form"

    curl -fsS -o /dev/null -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
        --data-urlencode "_token=${csrf_token}" \
        --data-urlencode "email=${ADMIN_EMAIL}" \
        --data-urlencode "password=${ADMIN_PASS}" \
        "${APP_URL}/login"
    dashboard_status=$(curl -sS -o /dev/null -w '%{http_code}' -b "${COOKIE_JAR}" "${APP_URL}/")
    [ "${dashboard_status}" = 200 ] || fail "GET / after login returned ${dashboard_status}"
}

assert_runs_unprivileged() {
    local image_user process_list root_processes program
    image_user=$(docker inspect -f '{{.Config.User}}' "${IMAGE}")
    [ "${image_user}" = 1000:1000 ] || fail "image USER is '${image_user}', expected 1000:1000"

    process_list=$(docker exec "${APP_CONTAINER}" ps -eo uid=,args=)
    root_processes=$(awk '$1 == 0' <<<"${process_list}")
    [ -z "${root_processes}" ] || fail "processes running as root: ${root_processes}"
    for program in 'nginx: master' 'php-fpm: master' 'queue:work' 'scheduler.sh'; do
        grep -qF -- "${program}" <<<"${process_list}" || fail "${program} is not running"
    done

    docker exec "${APP_CONTAINER}" sh -c "grep -q '^error_log = /proc/self/fd/2' /etc/php*/php-fpm.conf" \
        || fail "php-fpm error_log is not sent to stderr"
    docker exec "${APP_CONTAINER}" php -r 'exit(extension_loaded("intl") && extension_loaded("Zend OPcache") ? 0 : 1);' \
        || fail "intl or OPcache extension missing"
}

assert_modules_installed() {
    local tables table module_alias
    tables=$(docker exec "${DB_CONTAINER}" mariadb -ufreescout -p"${DB_PASS}" -N -e 'SHOW TABLES' freescout)
    for table in personal_templates presence_views; do
        grep -qx "${table}" <<<"${tables}" || fail "module table ${table} was not migrated"
    done
    for module_alias in personaltemplates presence; do
        docker exec "${APP_CONTAINER}" test -L "/var/www/html/public/modules/${module_alias}" \
            || fail "assets of module ${module_alias} are not published"
    done
}

docker network create "${NETWORK}" >/dev/null
docker run -d --name "${DB_CONTAINER}" --network "${NETWORK}" \
    -e MARIADB_ROOT_PASSWORD=root \
    -e MARIADB_DATABASE=freescout \
    -e MARIADB_USER=freescout \
    -e MARIADB_PASSWORD="${DB_PASS}" \
    mariadb:11 >/dev/null
wait_until "MariaDB" database_ready

echo "--- First start on an empty database"
start_app
first_start_logs=$(docker logs "${APP_CONTAINER}" 2>&1)
grep -q 'creating admin' <<<"${first_start_logs}" || fail "admin was not created on first start"
assert_admin_can_log_in
assert_runs_unprivileged
assert_modules_installed
app_key=$(docker exec "${APP_CONTAINER}" grep '^APP_KEY=' /data/.env)

echo "--- Recreated container on the same volume"
docker rm -f "${APP_CONTAINER}" >/dev/null
start_app
second_start_logs=$(docker logs "${APP_CONTAINER}" 2>&1)
if grep -q 'creating admin' <<<"${second_start_logs}"; then
    fail "admin re-created on restart"
fi
[ "$(docker exec "${APP_CONTAINER}" grep '^APP_KEY=' /data/.env)" = "${app_key}" ] || fail "APP_KEY changed"
assert_admin_can_log_in
app_running || fail "${APP_CONTAINER} stopped after start (a supervised program went FATAL)"

echo "PASS"
