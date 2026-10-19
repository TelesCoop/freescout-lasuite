#!/bin/sh
set -e

sleep_until_next_minute() {
    secs=$(date +%S | sed 's/^0*//')
    sleep $((60 - ${secs:-0}))
}

sleep_until_next_minute
while true; do
    php /var/www/html/artisan schedule:run --no-interaction 2>&1
    sleep_until_next_minute
done
