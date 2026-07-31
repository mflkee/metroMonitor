# Monitoring Stack

Отдельный стек мониторинга для `metroLog` и `metroGen`, не встроенный в их compose-файлы.

## Состав
- `prometheus`
- `grafana`
- `alertmanager`
- `node-exporter`
- `cadvisor`
- `blackbox-exporter`

## Что мониторится на первом этапе
- хост:
  - CPU
  - RAM
  - root filesystem
- контейнеры:
  - ресурсы через `cAdvisor`
- опубликованные HTTP endpoints:
  - `metroLog` frontend
  - `metroLog /api/v1/health`
  - `metroLog /api/v1/health/ready`
  - `metroGen` frontend
  - `metroGen /docs`
  - `metroGen /api/v1/resolve/status`
- опубликованные TCP сервисы:
  - `metroLog` Postgres
  - `metroLog` Redis
  - `metroGen` Postgres

## Важные принципы
- стек разворачивается отдельно в `/home/mflkee/apps/monitoring`
- порты мониторинга биндим только на `127.0.0.1`
- существующие стеки `metroLog` и `metroGen` не меняются
- `blackbox-exporter` ходит к host-портам приложений через `host.docker.internal`
- на этом сервере уже есть host-level `prometheus`, `grafana` и `node_exporter`, поэтому:
  - compose-`prometheus` использует порт `9091`
  - compose-`grafana` использует loopback-порт `8090`
  - compose-`node-exporter` работает только внутри monitoring network и не публикует `9100` на хост

## Подготовка
1. Скопировать пример переменных:

```bash
cd /home/mflkee/apps/monitoring
cp .env.example .env
```

2. Перед первым запуском заменить:
- `GRAFANA_ADMIN_PASSWORD`
- при необходимости скорректировать:
  - `GRAFANA_BIND_IP`, если Grafana нужно публиковать не только на loopback
  - `GRAFANA_PUBLIC_DOMAIN`
  - `GRAFANA_PUBLIC_SCHEME`

## Безопасная проверка конфигов

```bash
cd /home/mflkee/apps/monitoring
docker compose config
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" prom/prometheus:v3.9.1 promtool check config /etc/prometheus/prometheus.yml
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" prom/prometheus:v3.9.1 promtool check rules /etc/prometheus/alerts.yml
docker run --rm -v "$PWD/alertmanager:/etc/alertmanager:ro" prom/alertmanager:v0.30.0 amtool check-config /etc/alertmanager/alertmanager.yml
```

## Запуск

```bash
cd /home/mflkee/apps/monitoring
docker compose up -d
```

## Локальный доступ
- Grafana: `http://127.0.0.1:8090`
- Prometheus: `http://127.0.0.1:9091`
- Alertmanager: `http://127.0.0.1:9093`

## Публикация наружу через KeenDNS
- По умолчанию Grafana слушает только `127.0.0.1:8090`.
- Если нужен внешний доступ, задайте `GRAFANA_BIND_IP` явным актуальным IP хоста и только после этого обновляйте KeenDNS.
- После смены USB-сетевого адаптера или DHCP-адреса проверьте IP хоста заново, иначе Grafana останется привязана к старому адресу.

## После запуска обязательно проверить
- `docker compose ps`
- все targets в Prometheus -> `UP`
- дашборд `Apps Monitoring Overview` в Grafana
- что порты мониторинга не торчат наружу, а слушают только loopback

## Telegram-алерты
- Alertmanager шлёт алерты через `janw/alertmanager-telegram` (сервис `telegram-bot` в compose).
- Токен бота и chat_id задаются в `.env`: `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID` (см. `.env.example`).
- webhook Alertmanager → `http://telegram-bot:8080/alerts`.
- Проверка webhook:
  ```bash
  curl -X POST http://127.0.0.1:9093/api/v1/alerts -H 'Content-Type: application/json' -d '{"alerts":[{"status":"firing","labels":{"alertname":"Test","severity":"warning","service":"test"},"annotations":{"summary":"test alert","description":"check"}}]}'
  ```

## Stage-контейнеры
- Stage-пробы вынесены в отдельные jobs `blackbox-http-stg` / `blackbox-tcp-stg` с меткой `env="staging"`.
- Отслеживаются: `metroCheck` (backend :9002, frontend :9081, postgres :5436, redis :6383) и `metroGen` (api :9001, frontend :9174, postgres :5437).

## Что нужно сделать позже
- добавить app-level `/metrics`
- добавить app-level `/health/live` и `/health/ready` для `metroGen`
- перевести `metroGen` healthcheck с `/docs` на нормальный readiness endpoint
- решить вопрос с ротацией Docker логов
