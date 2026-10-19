#!/bin/sh
set -e

APP_DIR=/var/www/html
DATA_DIR=/data

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { printf '[entrypoint] %s\n' "$*"; }

escape_regex() { printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g'; }

set_env() {
    local key="$1" value="$2" env_file="${APP_DIR}/.env"
    local escaped_key
    escaped_key=$(escape_regex "${key}")
    sed -i "/^${escaped_key}=/d" "${env_file}" 2>/dev/null || true
    printf '%s=%s\n' "${key}" "${value}" >> "${env_file}"
}

del_env() {
    local key="$1" env_file="${APP_DIR}/.env"
    local escaped_key
    escaped_key=$(escape_regex "${key}")
    sed -i "/^${escaped_key}=/d" "${env_file}" 2>/dev/null || true
}

resolve_file_secrets() {
    local tmpfile
    tmpfile=$(mktemp)
    env | grep '_FILE=' > "${tmpfile}" 2>/dev/null || true
    while IFS='=' read -r key value; do
        local base_key="${key%_FILE}"
        if [ -f "${value}" ]; then
            export "${base_key}=$(cat "${value}")"
        fi
    done < "${tmpfile}"
    rm -f "${tmpfile}"
}

# ---------------------------------------------------------------------------
# Data directories & symlinks
# ---------------------------------------------------------------------------

setup_data() {
    mkdir -p "${DATA_DIR}/storage" "${DATA_DIR}/modules"

    if [ ! -d "${DATA_DIR}/storage/app" ]; then
        log "Initialising persistent storage from app skeleton"
        cp -a "${APP_DIR}/storage/." "${DATA_DIR}/storage/"
    fi

    if [ -d "${APP_DIR}/storage" ] && [ ! -L "${APP_DIR}/storage" ]; then
        rm -rf "${APP_DIR}/storage"
    fi
    ln -sfn "${DATA_DIR}/storage" "${APP_DIR}/storage"

    if [ -d "${APP_DIR}/Modules" ] && [ ! -L "${APP_DIR}/Modules" ]; then
        cp -a "${APP_DIR}/Modules/." "${DATA_DIR}/modules/" 2>/dev/null || true
        rm -rf "${APP_DIR}/Modules"
    fi
    ln -sfn "${DATA_DIR}/modules" "${APP_DIR}/Modules"
}

# ---------------------------------------------------------------------------
# .env configuration
# ---------------------------------------------------------------------------

configure_env() {
    local env_file="${APP_DIR}/.env"

    if [ ! -f "${env_file}" ]; then
        cat > "${env_file}" <<'EOF'
APP_NAME=FreeScout
APP_ENV=production
APP_DEBUG=false
APP_LOG=single
APP_DISABLE_UPDATING=true
EOF
    fi

    [ -n "${APP_KEY}" ]  && set_env APP_KEY "${APP_KEY}"
    [ -n "${APP_URL}" ]  && set_env APP_URL "${APP_URL}"

    local tz="${APP_TIMEZONE:-${TIMEZONE:-UTC}}"
    set_env APP_TIMEZONE "${tz}"

    case "${APP_URL}" in
        http://*)  set_env SESSION_SECURE_COOKIE false ;;
        https://*) set_env SESSION_SECURE_COOKIE true  ;;
    esac

    local app_host
    app_host=$(echo "${APP_URL}" | sed -nE 's|^https?://([^/:]+).*|\1|p')
    if [ -n "${app_host}" ]; then
        set_env APP_TRUSTED_HOSTS "${app_host},localhost,127.0.0.1"
    fi
    set_env APP_TRUSTED_PROXIES "${APP_TRUSTED_PROXIES:-*}"

    # Database
    case "${DB_TYPE:-mysql}" in
        pgsql|postgres*) set_env DB_CONNECTION pgsql ;;
        *)               set_env DB_CONNECTION mysql ;;
    esac
    [ -n "${DB_HOST}" ] && set_env DB_HOST     "${DB_HOST}"
    [ -n "${DB_PORT}" ] && set_env DB_PORT     "${DB_PORT}"
    [ -n "${DB_NAME}" ] && set_env DB_DATABASE "${DB_NAME}"
    [ -n "${DB_USER}" ] && set_env DB_USERNAME "${DB_USER}"
    [ -n "${DB_PASS}" ] && set_env DB_PASSWORD "${DB_PASS}"

    # Mail
    [ -n "${MAIL_DRIVER}" ] && set_env MAIL_DRIVER "${MAIL_DRIVER}"
    [ -n "${MAIL_HOST}" ]   && set_env MAIL_HOST   "${MAIL_HOST}"
    [ -n "${MAIL_PORT}" ]   && set_env MAIL_PORT   "${MAIL_PORT}"

    # Pass-through: FREESCOUT_* → strip prefix → .env
    local tmpfile
    tmpfile=$(mktemp)
    env | grep '^FREESCOUT_' | grep -v '_FILE=' > "${tmpfile}" 2>/dev/null || true
    while IFS='=' read -r key value; do
        local laravel_key="${key#FREESCOUT_}"
        case "${value}" in
            unset|null) del_env "${laravel_key}" ;;
            *)          set_env "${laravel_key}" "${value}" ;;
        esac
    done < "${tmpfile}"
    rm -f "${tmpfile}"
}

# ---------------------------------------------------------------------------
# Database readiness
# ---------------------------------------------------------------------------

wait_for_db() {
    local host="${DB_HOST}"
    local default_port=3306
    case "${DB_TYPE:-mysql}" in
        pgsql|postgres*) default_port=5432 ;;
    esac
    local port="${DB_PORT:-${default_port}}" tries=30

    if [ -z "${host}" ]; then return; fi
    log "Waiting for database at ${host}:${port}"
    while [ ${tries} -gt 0 ]; do
        if php -r "@fsockopen('${host}', ${port}, \$e, \$m, 1) ? exit(0) : exit(1);" 2>/dev/null; then
            log "Database reachable"
            return
        fi
        tries=$((tries - 1))
        sleep 2
    done
    log "WARNING: database not reachable after 60s — proceeding anyway"
}

db_is_populated() {
    php "${APP_DIR}/artisan" tinker --execute="
        try { \DB::connection()->getSchemaBuilder()->hasTable('migrations') ? exit(0) : exit(1); }
        catch (\Throwable \$e) { exit(1); }
    " 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

resolve_file_secrets
setup_data
configure_env

if ! grep -q '^APP_KEY=base64:' "${APP_DIR}/.env" 2>/dev/null; then
    log "Generating APP_KEY"
    php "${APP_DIR}/artisan" key:generate --no-interaction
fi

wait_for_db

if db_is_populated; then
    log "Running migrations"
    php "${APP_DIR}/artisan" migrate --no-interaction --force
else
    log "Empty database — running migrations + creating admin"
    php "${APP_DIR}/artisan" migrate --no-interaction --force

    php "${APP_DIR}/artisan" freescout:create-user \
        --no-interaction \
        --role=admin \
        --firstName="${ADMIN_FIRST_NAME:-Admin}" \
        --lastName="${ADMIN_LAST_NAME:-User}" \
        --email="${ADMIN_EMAIL:-admin@example.com}" \
        --password="${ADMIN_PASS:-freescout}"
fi

if [ -d "${APP_DIR}/Modules" ] && [ "$(ls -A "${APP_DIR}/Modules" 2>/dev/null)" ]; then
    log "Registering modules"
    yes | php "${APP_DIR}/artisan" freescout:module-install --no-ansi 2>/dev/null || true
fi

php "${APP_DIR}/artisan" storage:link --no-interaction 2>/dev/null || true
php "${APP_DIR}/artisan" config:clear --no-interaction
php "${APP_DIR}/artisan" freescout:clear-cache --no-interaction 2>/dev/null || true
php "${APP_DIR}/artisan" freescout:after-app-update --no-interaction 2>/dev/null || true

log "Ready — ${APP_URL:-http://localhost:8080}"
exec "$@"
