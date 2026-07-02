# Backend image for local dev (docker-compose) and Azure App Service.
FROM python:3.11-slim

WORKDIR /app
COPY pyproject.toml .
RUN pip install --no-cache-dir fastapi "uvicorn[standard]" sqlalchemy alembic \
    "psycopg[binary]" pydantic pydantic-settings azure-storage-blob

COPY cloud/ ./cloud/
COPY contracts/ ./contracts/
COPY alembic.ini .

EXPOSE 8000
# Apply migrations, then serve.
CMD ["sh", "-c", "alembic upgrade head && uvicorn cloud.app.main:app --host 0.0.0.0 --port 8000"]
