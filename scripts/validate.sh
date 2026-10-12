#!/usr/bin/env sh
# Проверка конфигов стека перед применением.
# Запускать из корня репозитория (в клоне на сервере — обязательно до push).
set -eu

PROM_IMAGE=prom/prometheus:v3.9.1
AM_IMAGE=prom/alertmanager:v0.30.0

echo "==> docker compose config"
docker compose config >/dev/null

echo "==> promtool check config"
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/etc/prometheus:ro" "$PROM_IMAGE" \
  check config /etc/prometheus/prometheus.yml

echo "==> promtool check rules"
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/etc/prometheus:ro" "$PROM_IMAGE" \
  check rules /etc/prometheus/alerts.yml

echo "==> amtool check-config"
docker run --rm --entrypoint amtool -v "$PWD/alertmanager:/etc/alertmanager:ro" "$AM_IMAGE" \
  check-config /etc/alertmanager/alertmanager.yml

echo "OK: конфиги валидны"
