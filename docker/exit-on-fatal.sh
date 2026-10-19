#!/bin/sh
# supervisord event listener: a program stuck in FATAL stops the container so the orchestrator restarts it.

printf 'READY\n'
while read -r event_header; do
    payload_length=$(printf '%s\n' "${event_header}" | sed -n 's/.*len:\([0-9]*\).*/\1/p')
    event_payload=$(head -c "${payload_length}")
    printf '[exit-on-fatal] %s entered FATAL, stopping container\n' "${event_payload}" >&2
    kill -TERM "$(cat /var/run/supervisord/supervisord.pid)"
    printf 'RESULT 2\nOK'
done
