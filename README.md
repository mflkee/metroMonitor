# metroMonitoring

Стек мониторинга МКАИР: Prometheus + Grafana + Alertmanager (+ Telegram-бот) +
node-exporter + cAdvisor + blackbox-exporter.

Развёрнут на `mkair-server-tmn`, рабочий каталог — `/srv/project/mkair-services/monitoring`
(именно этот каталог и есть клон репозитория, отдельного «деплоя» нет).
Этот репозиторий — **источник истины** для конфигов стека.

## Состав

| Сервис | Образ | Роль |
|---|---|---|
| `prometheus` | `prom/prometheus:v3.9.1` | сбор метрик, правила алертов, `--web.enable-lifecycle` |
| `alertmanager` | `prom/alertmanager:v0.30.0` | маршрутизация алертов |
| `telegram-bot` | `ghcr.io/janw/alertmanager-telegram:edge` | webhook → Telegram |
| `grafana` | `grafana/grafana:12.3.6` | дашборды (provisioning из файлов) |
| `blackbox-exporter` | `prom/blackbox-exporter:v0.28.0` | HTTP/TCP-пробы сервисов |
| `node-exporter` | `prom/node-exporter:v1.10.2` | метрики хоста |
| `cadvisor` | `ghcr.io/google/cadvisor:0.56.2` | метрики контейнеров |

## Порты на хосте

| Сервис | Bind | Наружу |
|---|---|---|
| Grafana | `${GRAFANA_BIND_IP}:8090` (сейчас `0.0.0.0`) | да, через Nginx Proxy Manager → `https://monitor.mkair-it.ru` |
| Prometheus | `127.0.0.1:9091` | нет |
| Alertmanager | `127.0.0.1:9093` | нет |
| blackbox-exporter | `127.0.0.1:9115` | нет |
| cAdvisor | `127.0.0.1:8085` | нет |
| node-exporter | не публикуется (только сеть `monitor`) | нет |

На хосте уже есть свои host-level `prometheus`, `grafana` и `node_exporter`, поэтому
compose-сервисы занимают 9091/8090 и не публикуют 9100.

## Что мониторится

`node-exporter`/`cadvisor` — хост (CPU, RAM, root/boot fs, температура, load) и контейнеры.
Остальное — пробы blackbox через `host.docker.internal` (прод/stage) либо по публичным URL.

### Прод

| Сервис | HTTP-пробы | TCP-пробы |
|---|---|---|
| metroLog | `:5173/`, `:8000/api/v1/health`, `:8000/api/v1/health/ready` | postgres `:5432`, redis `:6379` |
| metroGen | `:5174/`, `:8001/docs`, `:8001/api/v1/resolve/status` | postgres `:5433` |
| metroCheck | `:8002/health` | postgres `:5434`, redis `:6382` |
| metroAuth | `https://auth.mkair-it.ru/`, `:8006/api/v1/health` | — |

### Stage (метка `env="staging"`)

| Сервис | HTTP-пробы | TCP-пробы |
|---|---|---|
| metroCheck | `:9002/health`, `:9002/health/live`, `:9081/` | postgres `:5436`, redis `:6383` |
| metroGen | `:9001/api/v1/resolve/status`, `:9001/docs`, `:9174/` | postgres `:5437` |
| metroAuth | `:9186/`, `:9006/api/v1/health` | — |

### Mail / Cloud (jobs `mail-http`, `mail-tcp`)

Stalwart (`mail.mkair-it.ru/login`, `/.well-known/oauth-authorization-server`),
Bulwark (`webmail.mkair-it.ru`), Nextcloud (`cloud.mkair-it.ru`),
порты `993`/`465`/`587`/`143` (IMAP/SMTP), `80`/`81` (NPM).

## Рабочий цикл (как менять конфиг)

Правки делаются в клоне на сервере, а не «на месте в контейнере»:

```bash
cd /srv/project/mkair-services/monitoring
git pull --rebase --autostash

# ... правим prometheus/prometheus.yml, alerts.yml, compose и т.п. ...
scripts/validate.sh              # обязательная проверка синтаксиса

docker compose up -d             # применить (пересоздаёт затронутые контейнеры)
# либо без пересоздания, только перечитать конфиг Prometheus:
curl -X POST http://127.0.0.1:9091/-/reload
# Alertmanager перечитывает конфиг сам (SIGHUP) либо docker compose restart alertmanager

git add -A && git commit -m "..." && git push
```

Дашборды Grafana **не редактируются в UI** — они провижнятся read-only из
`grafana/dashboards/overview.json`. Правки вносить в файл, затем `docker compose up -d grafana`.

## Проверка конфигов

```bash
scripts/validate.sh
```

Скрипт прогоняет `docker compose config`, `promtool check config`, `promtool check rules`
и `amtool check-config` в тех же образах, что и стек.

## Развёртывание с нуля

```bash
git clone git@github.com:mflkee/metroMonitoring.git /srv/project/mkair-services/monitoring
cd /srv/project/mkair-services/monitoring
cp .env.example .env      # заполнить GRAFANA_ADMIN_PASSWORD, TELEGRAM_TOKEN, TELEGRAM_CHAT_ID
docker network create monitor    # сеть объявлена external: true и в репозитории не создаётся
docker compose up -d
```

Тома состояния — `monitor_prometheus_data`, `monitor_grafana_data`,
`monitor_alertmanager_data` (имя проекта compose — `monitor`).

## Секреты

Все секреты только в `.env` (в `.gitignore`, в репозиторий не попадает):
`GRAFANA_ADMIN_PASSWORD`, `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`.
Шаблон с описанием переменных — `.env.example`.

## Алерты

Правила — `prometheus/alerts.yml`: недоступность таргетов стека, здоровье хоста
(CPU/RAM/fs/temperature/load), провал HTTP/TCP-проб, readness metroLog,
«все эндпоинты сервиса лежат».

Маршрут Alertmanager: `severity = critical|warning` → receiver `telegram`
(`send_resolved: true`), группировка по `alertname/severity/service`,
`repeat_interval: 4h`. Остальное уходит в `default-null`.

Проверка webhook:

```bash
curl -X POST http://127.0.0.1:9093/api/v1/alerts -H 'Content-Type: application/json' \
  -d '{"alerts":[{"status":"firing","labels":{"alertname":"Test","severity":"warning","service":"test"},"annotations":{"summary":"test alert","description":"check"}}]}'
```

## Известные хвосты

- у проб mail/cloud (`mail-http`, `mail-tcp`) нет правил алертов — они собираются, но не алертят;
- `GRAFANA_BIND_IP=0.0.0.0` — порт `8090` слушает все интерфейсы (это нужно NPM в докере),
  при политике файрвола `accept` страница логина Grafana доступна из сети; при желании сузить,
  не сломав NPM;
- app-level `/metrics` у сервисов так и не появились (метрики только инфраструктурные);
- у metroGen нет `/health/live` и `/health/ready`, проба ходит в `/docs`;
- ротация Docker-логов не настроена;
- на хосте остались тома старого стека `monitoring_prometheus_data`,
  `monitoring_grafana_data`, `monitoring_alertmanager_data` и сеть `monitoring_monitoring`.
