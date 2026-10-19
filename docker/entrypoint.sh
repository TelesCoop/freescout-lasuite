#!/bin/sh
set -e

APP_DIR=/var/www/html
DATA_DIR=/data
ENV_FILE="${DATA_DIR}/.env"

log() { printf '[entrypoint] %s\n' "$*"; }

fail() {
    printf '[entrypoint] ERROR: %s\n' "$*" >&2
    exit 1
}

require_var() {
    eval "required_value=\${$1:-}"
    [ -n "${required_value}" ] || fail "$1 is required: $2"
}

artisan() { php "${APP_DIR}/artisan" "$@" --no-interaction; }

del_env() {
    local escaped_key
    escaped_key=$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g')
    sed -i "/^${escaped_key}=/d" "${ENV_FILE}"
}

set_env() {
    local escaped_value
    escaped_value=$(printf '%s' "$2" | sed 's/[\\"]/\\&/g')
    del_env "$1"
    printf '%s="%s"\n' "$1" "${escaped_value}" >> "${ENV_FILE}"
}

resolve_file_secrets() {
    local env_line file_var secret_path
    while IFS= read -r env_line; do
        [ -n "${env_line}" ] || continue
        file_var="${env_line%%=*}"
        secret_path="${env_line#*=}"
        [ -f "${secret_path}" ] || fail "${file_var} points to a missing file: ${secret_path}"
        export "${file_var%_FILE}=$(cat "${secret_path}")"
    done <<EOF
$(env | sed -n '/^[A-Za-z_][A-Za-z0-9_]*_FILE=/p')
EOF
}

link_persistent_storage() {
    if [ -L "${APP_DIR}/storage" ]; then
        return
    fi
    if [ ! -d "${DATA_DIR}/storage" ]; then
        cp -a "${APP_DIR}/storage" "${DATA_DIR}/storage"
    fi
    rm -rf "${APP_DIR}/storage"
    ln -s "${DATA_DIR}/storage" "${APP_DIR}/storage"
}

configure_env() {
    local app_url_lowercase app_host env_line prefixed_key value

    require_var APP_URL "external URL, e.g. https://freescout.example.com"
    require_var DB_HOST "database hostname"
    require_var DB_NAME "database name"
    require_var DB_USER "database user"
    require_var DB_PASS "database password"

    app_url_lowercase=$(printf '%s' "${APP_URL}" | tr '[:upper:]' '[:lower:]')
    app_host=$(printf '%s' "${app_url_lowercase}" | sed -nE 's|^https?://([^/:]+).*|\1|p')
    [ -n "${app_host}" ] || fail "APP_URL must start with http:// or https:// (got '${APP_URL}')"

    case "${DB_TYPE:-mysql}" in
        mysql|mariadb)   DB_CONNECTION=mysql; DB_PORT="${DB_PORT:-3306}" ;;
        pgsql|postgres*) DB_CONNECTION=pgsql; DB_PORT="${DB_PORT:-5432}" ;;
        *)               fail "DB_TYPE must be mysql, mariadb or pgsql (got '${DB_TYPE}')" ;;
    esac

    touch "${ENV_FILE}"
    ln -sfn "${ENV_FILE}" "${APP_DIR}/.env"

    set_env APP_URL "${APP_URL}"
    set_env APP_TRUSTED_HOSTS "${app_host},localhost,127.0.0.1"
    set_env APP_TIMEZONE "${TIMEZONE:-UTC}"
    set_env APP_DISABLE_UPDATING true
    case "${app_url_lowercase}" in
        https://*) set_env SESSION_SECURE_COOKIE true ;;
        *)         set_env SESSION_SECURE_COOKIE false ;;
    esac

    set_env DB_CONNECTION "${DB_CONNECTION}"
    set_env DB_HOST "${DB_HOST}"
    set_env DB_PORT "${DB_PORT}"
    set_env DB_DATABASE "${DB_NAME}"
    set_env DB_USERNAME "${DB_USER}"
    set_env DB_PASSWORD "${DB_PASS}"

    while IFS= read -r env_line; do
        [ -n "${env_line}" ] || continue
        prefixed_key="${env_line%%=*}"
        value="${env_line#*=}"
        case "${value}" in
            ''|unset|null) del_env "${prefixed_key#FREESCOUT_}" ;;
            *)             set_env "${prefixed_key#FREESCOUT_}" "${value}" ;;
        esac
    done <<EOF
$(env | sed -n -e '/^FREESCOUT_[A-Za-z0-9_]*_FILE=/d' -e '/^FREESCOUT_/p')
EOF
}

ensure_app_key() {
    if [ -n "${APP_KEY:-}" ]; then
        set_env APP_KEY "${APP_KEY}"
    elif ! grep -Eq '^APP_KEY="?base64:' "${ENV_FILE}"; then
        log "Generating APP_KEY into ${ENV_FILE}"
        set_env APP_KEY "base64:$(head -c 32 /dev/urandom | base64)"
    fi
}

wait_for_db() {
    local attempts=30
    log "Waiting for database at ${DB_HOST}:${DB_PORT}"
    until php -r 'exit(@fsockopen($argv[1], (int) $argv[2], $errno, $errstr, 1) ? 0 : 1);' -- "${DB_HOST}" "${DB_PORT}"; do
        attempts=$((attempts - 1))
        [ "${attempts}" -gt 0 ] || fail "database ${DB_HOST}:${DB_PORT} unreachable after 60s"
        sleep 2
    done
}

create_admin_if_no_users() {
    local users_query_status=0
    php -r '
        require "/var/www/html/vendor/autoload.php";
        $app = require "/var/www/html/bootstrap/app.php";
        $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
        exit(Illuminate\Support\Facades\DB::table("users")->exists() ? 0 : 1);
    ' || users_query_status=$?

    case "${users_query_status}" in
        0) return ;;
        1) ;;
        *) fail "could not query the users table" ;;
    esac

    require_var ADMIN_EMAIL "no user exists yet, an admin account must be created"
    require_var ADMIN_PASS "no user exists yet, an admin account must be created"
    log "No user found, creating admin ${ADMIN_EMAIL}"
    artisan freescout:create-user \
        --role=admin \
        --firstName="${ADMIN_FIRST_NAME:-Admin}" \
        --lastName="${ADMIN_LAST_NAME:-User}" \
        --email="${ADMIN_EMAIL}" \
        --password="${ADMIN_PASS}"
}

# Runs after freescout:after-app-update, which clears the cached module list.
migrate_modules() {
    local module_manifest module_name
    for module_manifest in "${APP_DIR}"/Modules/*/module.json; do
        module_name=$(basename "$(dirname "${module_manifest}")")
        log "Migrating module ${module_name}"
        artisan module:migrate "${module_name}" --force
    done
}

resolve_file_secrets
link_persistent_storage
configure_env
ensure_app_key
wait_for_db
artisan migrate --force
create_admin_if_no_users
artisan freescout:after-app-update
migrate_modules

log "Starting services for ${APP_URL}"
exec "$@"
