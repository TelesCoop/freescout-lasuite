#!/bin/sh
set -e

APP_KEY=$(grep '^APP_KEY=' /var/www/html/.env 2>/dev/null | cut -d'=' -f2-)
if [ -n "${APP_KEY}" ]; then
    IDENTIFIER=$(printf '%s' "${APP_KEY}" | md5sum | cut -d' ' -f1)
    QUEUES="emails,default,${IDENTIFIER}"
else
    QUEUES="emails,default"
fi

exec php /var/www/html/artisan queue:work \
    --queue="${QUEUES}" \
    --sleep=5 \
    --tries=1 \
    --timeout=1800
