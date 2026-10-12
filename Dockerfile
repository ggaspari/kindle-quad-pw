# Quad Board server. Build from the repo root:  docker build -t kindle-quad-pw .
FROM python:3.12-slim

# tzdata: TZ=America/Sao_Paulo needs the zone files the slim image leaves out.
# Node + Claude Code: the CLI behind the one-line brief (sources.brief runs
# `claude -p`); it authenticates with CLAUDE_CODE_OAUTH_TOKEN from .env.
RUN apt-get update && apt-get install -y --no-install-recommends tzdata nodejs npm \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/server
COPY server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server/ .

ENV PYTHONUNBUFFERED=1 \
    DISABLE_AUTOUPDATER=1 \
    TZ=America/Sao_Paulo \
    QUAD_BIND=0.0.0.0 \
    QUAD_PORT=8740 \
    QUAD_CONFIG=/data/config.json \
    QUAD_STATE=/data/state.json

# settings + state, and the logo / flight-route cache
VOLUME ["/data", "/app/server/cache"]
EXPOSE 8740

HEALTHCHECK --interval=60s --timeout=5s --start-period=60s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8740/healthz', timeout=4)"

CMD ["python", "app.py"]
