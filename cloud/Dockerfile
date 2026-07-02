# Backend image for local dev (docker-compose) and Azure App Service.
FROM python:3.11-slim

WORKDIR /app
COPY pyproject.toml .
RUN pip install --no-cache-dir fastapi "uvicorn[standard]" sqlalchemy alembic \
    "psycopg[binary]" pydantic pydantic-settings azure-storage-blob

COPY cloud/ ./cloud/
COPY contracts/ ./contracts/
COPY dashboard/summary/ ./dashboard/summary/
COPY alembic.ini .

EXPOSE 8000
# Apply migrations (retrying while the DB comes up), then serve.
# If migrations never apply, exit instead of serving against a missing table.
CMD ["sh", "-c", "ok=; for i in $(seq 1 15); do alembic upgrade head && ok=1 && break; echo 'migration failed, retrying...'; sleep 2; done; [ -n \"$ok\" ] || exit 1; uvicorn cloud.app.main:app --host 0.0.0.0 --port 8000"]
