FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_DEFAULT_TIMEOUT=60 \
    PIP_RETRIES=5

WORKDIR /app

RUN groupadd --system app && useradd --system --gid app --create-home app
RUN mkdir -p /var/log/auto-trade && chown app:app /var/log/auto-trade

COPY pyproject.toml README.md ./
COPY src ./src
RUN --mount=type=cache,target=/root/.cache/pip python -m pip install .

USER app
EXPOSE 8000

CMD ["uvicorn", "auto_trade.main:app", "--host", "0.0.0.0", "--port", "8000"]

FROM base AS test

USER root
COPY tests ./tests
RUN --mount=type=cache,target=/root/.cache/pip python -m pip install '.[dev]'
USER app

CMD ["pytest"]
