#!/bin/sh
set -e

app_key=$(sed -n 's/^APP_KEY="\(.*\)"$/\1/p' /data/.env)
if [ -z "${app_key}" ]; then
    echo '[worker] APP_KEY missing from /data/.env' >&2
    exit 1
fi
worker_identifier=$(printf '%s' "${app_key}" | md5sum | cut -d' ' -f1)

exec php /var/www/html/artisan queue:work \
    --queue="emails,default,${worker_identifier}" \
    --sleep=5 \
    --tries=1 \
    --timeout=1800
