#!/usr/bin/env bash

set -euo pipefail

trap 'echo "ОШИБКА: скрипт прерван на строке $LINENO"; exit 1' ERR

cd "$(dirname "$0")"

if ! command -v docker >/dev/null 2>&1; then
  echo "Ошибка: docker не установлен"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Ошибка: нет доступа к Docker-демону (запущен ли он?)"
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "Ошибка: openssl не установлен"
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
  sed -i \
    -e "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=$(openssl rand -hex 16)|" \
    -e "s|^WOODPECKER_AGENT_SECRET=.*|WOODPECKER_AGENT_SECRET=$(openssl rand -hex 16)|" \
    -e "s|^REGISTRY_PASSWORD=.*|REGISTRY_PASSWORD=$(openssl rand -hex 16)|" \
    -e "s|^REGISTRY_HTTP_SECRET=.*|REGISTRY_HTTP_SECRET=$(openssl rand -hex 24)|" \
    .env
  chmod 600 .env
  echo ">> Создан .env со случайными паролями (все данные доступа ниже и в README)"
fi

source .env

if [[ -z "${REGISTRY_USER}" || -z "${REGISTRY_PASSWORD}" ]]; then
  echo "ОШИБКА: REGISTRY_USER или REGISTRY_PASSWORD не заданы в .env"
  exit 1
fi

mkdir -p registry/auth
docker pull httpd:2.4-alpine >/dev/null \
  || { echo "Не удалось скачать образ httpd:2.4-alpine"; exit 1; }

docker run --rm --entrypoint htpasswd httpd:2.4-alpine \
  -Bbn "${REGISTRY_USER}" "${REGISTRY_PASSWORD}" > registry/auth/htpasswd

if [[ ! -s registry/auth/htpasswd ]]; then
  echo "ОШИБКА: htpasswd не создан"
  exit 1
fi

chmod 600 registry/auth/htpasswd
echo ">> Файл registry/auth/htpasswd перегенерирован (пользователь ${REGISTRY_USER})"

docker compose up -d

echo
echo ">> Ожидание готовности Gitea"
ready=0
for _ in $(seq 1 60); do
  if curl -sf "http://localhost:${GITEA_PORT:-3000}/api/healthz" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  echo "Gitea не поднялся, логи:"
  docker compose logs --tail=50 gitea
  exit 1
fi
echo ">> Gitea готов"

if ! docker compose exec -T -u 1000 gitea gitea admin user create --admin \
      --username "${ADMIN_USER}" \
      --password "${ADMIN_PASSWORD}" \
      --email "${ADMIN_EMAIL}" \
      --must-change-password=false >/dev/null 2>&1; then
  echo ">> Пользователь ${ADMIN_USER} уже существует (ok)"
fi

echo
echo ">> Ожидание готовности Registry"
reg_code="000"
for _ in $(seq 1 20); do
  reg_code=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:${REGISTRY_PORT:-5000}/v2/" || true)
  [[ "${reg_code}" == "401" || "${reg_code}" == "200" ]] && break
  sleep 1
done
if [[ "${reg_code}" != "401" && "${reg_code}" != "200" ]]; then
  echo "Registry не отвечает (HTTP ${reg_code}), логи:"
  docker compose logs --tail=30 registry
  exit 1
fi
echo ">> Registry готов (HTTP ${reg_code}, требуется авторизация)"

echo
echo "================================================================="
echo " Все сервисы запущены (network_mode: host, Linux-only)"
echo "================================================================="
echo " Gitea        : http://localhost:${GITEA_PORT:-3000}"
echo " Woodpecker   : http://localhost:${WOODPECKER_PORT:-8000}"
echo " Registry     : 127.0.0.1:${REGISTRY_PORT:-5000}  (docker login localhost:${REGISTRY_PORT:-5000})"
echo " Деплой демо  : http://localhost:${APP_DEPLOY_PORT:-8090}"
echo
echo " Логин/пароль Gitea : ${ADMIN_USER} / ${ADMIN_PASSWORD}   (см. .env)"
echo " Логин/пароль Registry: ${REGISTRY_USER} / ${REGISTRY_PASSWORD} (см. .env)"
echo
echo " СЛЕДУЮЩИЕ ШАГИ (подробности в README.md):"
echo "  1. Войдите в Gitea как ${ADMIN_USER}"
echo "  2. Gitea -> Settings -> Applications -> Manage OAuth2 ->"
echo "     создайте приложение Woodpecker с redirect URI:"
echo "     http://localhost:${WOODPECKER_PORT:-8000}/authorize"
echo "  3. Впишите Client ID и Client Secret в .env:"
echo "       WOODPECKER_GITEA_CLIENT=..."
echo "       WOODPECKER_GITEA_SECRET=..."
echo "  4. docker compose up -d --force-recreate"
echo "  5. Woodpecker -> Login через Gitea -> включите репозиторий"
echo "  6. Добавьте secrets: registry_user и registry_password"
echo "================================================================="
