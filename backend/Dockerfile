# Use Astral's uv base image with Python 3.11
FROM ghcr.io/astral-sh/uv:python3.11-alpine

# Set environment
ENV ENV_MODE=production
WORKDIR /app

# Install required system packages
RUN apk add --no-cache curl git

# Install Python dependencies
COPY pyproject.toml uv.lock ./
ENV UV_LINK_MODE=copy
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked --verbose

# Copy application code
COPY . .

# Resource tuning for Render Free (0.1 CPU, 512 MB RAM)
ENV WORKERS=1
ENV THREADS=1
ENV WORKER_CONNECTIONS=100
ENV PYTHONPATH=/app

EXPOSE 8000

# Start with Gunicorn (safe for production, tuned down for low resources)
CMD ["sh", "-c", "uv run gunicorn api:app \
  --workers $WORKERS \
  --worker-class uvicorn.workers.UvicornWorker \
  --bind 0.0.0.0:8000 \
  --timeout 600 \
  --graceful-timeout 300 \
  --keep-alive 75 \
  --worker-connections $WORKER_CONNECTIONS \
  --log-level info \
  --access-logfile - \
  --error-logfile - \
  --capture-output"]
