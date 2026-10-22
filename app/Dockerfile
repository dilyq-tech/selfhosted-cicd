# syntax=docker/dockerfile:1

# ---------- Stage 1: собираем зависимости в wheels ----------
FROM python:3.12-alpine AS builder

WORKDIR /build

COPY requirements.txt .

RUN pip install --no-cache-dir --upgrade pip \
    && pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

# ---------- Stage 2: минимальный runtime-образ ----------
FROM python:3.12-alpine

# ставим только финальные зависимости из готовых wheels
COPY --from=builder /wheels /wheels
RUN apk --no-cache upgrade \
    && pip install --no-cache-dir --no-index --find-links=/wheels "flask==3.1.0" \
    && rm -rf /wheels

# запуск не от root
RUN addgroup -S app && adduser -S app -G app

WORKDIR /app

COPY --chown=app:app app.py .

USER app

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request, sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8001/health', timeout=4).getcode() == 200 else 1)"

CMD ["python", "app.py"]
