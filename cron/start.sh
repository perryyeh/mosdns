#!/bin/sh
# mosdns entrypoint - start crond then mosdns

# Ensure runtime directories exist
mkdir -p /etc/mosdns/tmp

# Install crontab from mounted volume
crontab /etc/mosdns/cron/crontab

# Start crond in background
crond -b -l 8

# Start mosdns
exec /usr/bin/mosdns start --dir /etc/mosdns
