# Self-Hosted CI/CD: Gitea + Woodpecker CI + приватный Registry + Trivy

Автономная CI/CD-система целиком на Docker Compose:

| Компонент | Роль | Адрес |
|---|---|---|
| Gitea | Git-сервер, статус пайплайнов в UI | http://localhost:3000 |
| Woodpecker CI | Пайплайны (форк Drone, активно развивается) | http://localhost:8000 |
| Docker Registry v2 | Приватный реестр образов (htpasswd-авторизация) | 127.0.0.1:5000 |
| Trivy | Сканер уязвимостей образов (CVE) | шаг `scan` в пайплайне |
| Демо-приложение Flask | то, что собирает пайплайн | http://localhost:8090 |

Вся служебная инфраструктура работает через `network_mode: host` (Linux) —
все сервисы и шаги пайплайна видят друг друга на `localhost`, не требует
insecure-registry конфигов у Docker-демона и работает из коробки.

## Как это работает

```
Разработчик
    │ git push
    ▼
Gitea :3000  ──(webhook)──►  Woodpecker :8000
                                 │
   ┌─────────────────────────────┴──────────────────────────┐
   │ 1. clone  - забирает код из Gitea                      │
   │ 2. test   - pytest внутри python:3.12-slim             │
   │ 3. build  - docker build (через docker.sock хоста)     │
   │ 4. scan   - Trivy сканирует образ                      │
   │             └─ CRITICAL (неисправленные) → пайплайн ПАДАЕТ,│
   │                push/deploy не случаются                │
   │ 5. push   - docker login + docker push в registry:5000 │
   │ 6. deploy - docker run demo-приложения на порт 8090    │
   └────────────────────────────────────────────────────────┘
```

- Статусы пайплайнов видны в UI Woodpecker и в коммитах Gitea (commit-status).
- Список образов в реестре: `./registry-catalog.sh` (логин/пароль из `.env`).
- Логи сканирования Trivy лежат в логе шага `scan` в Woodpecker — там же
  полная таблица найденных CVE.

## Требования

- Linux + Docker (движок 24+) + Docker Compose v2 (`docker compose version`)
- свободные порты: 3000, 8000, 9000, 5000, 8090 (меняются в `.env`)
- ~1.5 ГБ диска под образы и volumes, доступ в интернет (Trivy качает БД CVE)

## Быстрый старт

```bash
cd ~/selfhosted-cicd
bash setup.sh
```

`setup.sh` создаст `.env` со случайными паролями (или возьмёт существующий),
сгенерирует htpasswd для registry, запустит всю кучу и создаст админа в Gitea.

| Что | Значение |
|---|---|
| Gitea логин/пароль | `ci-admin` / см. `ADMIN_PASSWORD` в `.env` |
| Registry логин/пароль | `admin` / см. `REGISTRY_PASSWORD` в `.env` |

### Шаг 1: OAuth-приложение Gitea для Woodpecker

1. Войдите в **http://localhost:3000** под `ci-admin`.
2. Правый верхний угол → **Settings → Applications → Manage OAuth2 applications**.
3. Создайте приложение «Woodpecker» с Redirect URI:
   ```
   http://localhost:8000/authorize
   ```
4. Скопируйте **Client ID / Client Secret** в `.env`:
   ```
   WOODPECKER_GITEA_CLIENT=<client id>
   WOODPECKER_GITEA_SECRET=<client secret>
   ```
5. Пересоздайте контейнер Woodpecker:
   ```bash
   docker compose up -d --force-recreate
   ```

### Шаг 2: Включить репозиторий в CI

1. Откройте **http://localhost:8000** → войдите через Gitea под `ci-admin`.
2. Список репозиториев → **Enable Repository** у репозитория с демо-приложением.

### Шаг 3: Залить демо-приложение

```bash
cd app
git init
git add .
git commit -m "init: cicd demo app"
git branch -M main
git remote add origin http://localhost:3000/ci-admin/cicd-demo-app.git
git push -u origin main
```

Gitea попросит учётные данные — username `ci-admin`, пароль из `.env`.

### Шаг 4: Секреты для пуша в Registry

В Woodpecker: репозиторий → **Settings → Secrets → Add Secret**:

| Secret | Значение |
|---|---|
| `registry_user` | `admin` |
| `registry_password` | значение `REGISTRY_PASSWORD` из `.env` |

### Шаг 5: Смотреть пайплайн

- Woodpecker UI: воркфлоу с шагами test → build → scan → push → deploy.
- Приложение: `curl http://localhost:8090/`
- Список образов в реестре: `./registry-catalog.sh`
- Логин в реестр руками:
  ```bash
  docker login localhost:5000        # admin / REGISTRY_PASSWORD
  docker pull localhost:5000/cicd-lab/demo-app:latest
  ```

## Пайплайн (app/.woodpecker.yml)

| Шаг | Что делает | Если упал |
|---|---|---|
| `test` | `pip install` + `pytest` | пайплайн красный дальше не идёт |
| `build` | `docker build` + `docker save app.tar` | то же |
| `scan` | `trivy image --input app.tar --severity CRITICAL --ignore-unfixed --exit-code 1` | **CRITICAL CVE найдены → пайплайн красный, push/deploy отменяются**; вторая команда (без exit-code) печатает полную таблицу HIGH+CRITICAL для просмотра |
| `push` | `docker login`, push sha-тега и `latest` | то же |
| `deploy` | `docker rm -f` старого контейнера, `docker run -p 8090:8001`, healthcheck через wget | то же |

Сборка/пуш идут через `docker.sock` хоста (шаги контейнеры только «командуют»),
поэтому кэш сборки общий с обычными `docker build`, а registry доступен просто
как `localhost:5000`. Tag-схема: `cicd-lab/demo-app:<commit-sha>` + `latest`.

### Как продемонстрировать «пайплайн падает из-за CVE»

Замените базовый образ в `app/Dockerfile` на старый, с кучей незакрытых CVE,
и запушьте:

```bash
sed -i 's|FROM python:3.12-slim|FROM python:3.8-slim-bullseye|' app/Dockerfile
cd app && git commit -am "demo: vulnerable base image" && git push
```

Шаг `scan` найдёт критические уязвимости, пайплайн станет красным, а в логах
шага `scan` будет таблица CVE. Верните `python:3.12-slim`, чтобы починить.
Порог жёсткости регулируется в `app/.woodpecker.yml`: добавьте HIGH к
`--severity` или уберите `--ignore-unfixed`, если хотите строгий режим.

## Работа с приватным реестром

```bash
docker login localhost:5000            # пароль из .env (REGISTRY_PASSWORD)
docker tag myimage localhost:5000/cicd-lab/test:dev
docker push localhost:5000/cicd-lab/test:dev
./registry-catalog.sh                  # какие образы есть в реестре
```

Данные образов — volume `registry-data`, git-данные — `gitea-data`,
БД и логи Woodpecker — `woodpecker-data`; кэш БД CVE Trivy — `trivy-cache`.
Все это именованные volume, уничтожаются `docker compose down -v`.

## Деплой на настоящий тестовый сервер

Шаг `deploy` здесь крутит контейнер на той же машине (наглядно и безопасно).
Для удалённого сервера замените шаг `deploy` на SSH-плагин:

```yaml
  deploy:
    image: appleboy/drone-ssh
    depends_on: [push]
    settings:
      host: 192.168.1.50
      username: ci
      key:
        from_secret: deploy_ssh_key
      script:
        - docker pull localhost:5000/cicd-lab/demo-app:latest
        - docker rm -f cicd-demo-app
        - docker run -d --name cicd-demo-app -p 8090:8001 localhost:5000/cicd-lab/demo-app:latest
```

(тогда на сервере тоже нужно разрешить insecure registry `localhost:5000`
или настроить HTTPS для registry).

## Безопасность и что менять перед «боем»

- Registry слушает только `127.0.0.1` (`REGISTRY_HTTP_ADDR`) — не торчит наружу.
- `.env` сгенерирован с правами 600 и в `.gitignore` — там пароли.
- Шаги пайплайна имеют доступ к `docker.sock` хоста = root на хосте. Это
  упрощение для лабы; для продакшена выносите билд в rootless/dockerd
  или используйте kaniko (`woodpeckerci/plugin-docker-buildx`, без DinD/DinSock).
- Trivy тянет свежую базу CVE при запуске (кэш в volume `trivy-cache`);
  для полностью offline: `trivy image --download-db-only` локально и проброс.

## Harbor вместо Docker Registry

Если нужна «пометка об уязвимостях» прямо в UI реестра (как в Harbor с Trivy
отчётами) — реестр меняется на Harbor (10+ контейнеров, много ОЗУ). Сценарий
с Docker Registry + Trivy показан выше; отчёты по CVE каждого образа
открываются в логе шага `scan` в Woodpecker.

## Управление

```bash
make up      # поднять все сервисы
make down    # остановить
make ps      # статус
make logs    # логи
make reset   # остановить и УДАЛИТЬ данные (volumes)
docker compose logs -f gitea
```

## Траблшутинг

| Проблема | Решение |
|---|---|
| Порт занят | Поменяйте в `.env`, затем `docker compose up -d --force-recreate` |
| Woodpecker: пуст список репозиториев | Проверьте OAuth (шаг 1), затем force-recreate |
| `docker login localhost:5000` возвращает 401 | `.env` и `registry/auth/htpasswd` рассинхронизированы — прогоните `setup.sh` заново |
| Trivy timeout при загрузке БД | Прокиньте прокси в `.env`/agent или качайте БД оффлайн-файлом |
| Docker Desktop / WSL2 | `network_mode: host` linux-only; нужен bridge-вариант — пишите, сделаю |
