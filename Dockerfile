FROM python:3.11-slim AS builder

ARG HERMES_GIT_REF

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN HERMES_REF="${HERMES_GIT_REF:-main}" \
  && git init /opt/hermes-agent \
  && git -C /opt/hermes-agent remote add origin https://github.com/NousResearch/hermes-agent.git \
  && git -C /opt/hermes-agent fetch --depth 1 origin "${HERMES_REF}" \
  && git -C /opt/hermes-agent checkout --detach FETCH_HEAD \
  && git -C /opt/hermes-agent submodule update --init --recursive --depth 1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel
RUN pip install --no-cache-dir websockets -e "/opt/hermes-agent[messaging,cron,cli,pty]"


FROM python:3.11-slim

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
  PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    chromium \
    curl \
    fonts-liberation \
    git \
    gosu \
    gh \
    nodejs \
    npm \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g playwright \
  && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=0 playwright install chromium

ENV PATH="/opt/venv/bin:${PATH}" \
  PYTHONUNBUFFERED=1 \
  HERMES_HOME=/data/.hermes \
  HOME=/data

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/hermes-agent /opt/hermes-agent

WORKDIR /app
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
COPY scripts/entrypoint_check.sh /app/scripts/entrypoint_check.sh
RUN addgroup --system --gid 10001 hermes \
  && adduser --system --uid 10001 --ingroup hermes --home /data hermes \
  && mkdir -p /data /data/workspace /ms-playwright \
  && chown -R hermes:hermes /app /data /ms-playwright \
  && chmod +x /app/scripts/entrypoint.sh /app/scripts/entrypoint_check.sh

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint_check.sh"]
