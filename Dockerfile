# syntax=docker/dockerfile:1.7

ARG NODE_VERSION=22.13.0

FROM node:${NODE_VERSION}-bookworm-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci && npm cache clean --force

FROM deps AS build
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1
ARG NEXT_PUBLIC_QUOTE_LAUNCHPAD=
ARG NEXT_PUBLIC_QUOTE_API_URL=
ARG NEXT_PUBLIC_QUOTE_WS_URL=
ENV NEXT_PUBLIC_QUOTE_LAUNCHPAD=${NEXT_PUBLIC_QUOTE_LAUNCHPAD} \
    NEXT_PUBLIC_QUOTE_API_URL=${NEXT_PUBLIC_QUOTE_API_URL} \
    NEXT_PUBLIC_QUOTE_WS_URL=${NEXT_PUBLIC_QUOTE_WS_URL}
COPY . .
RUN npm run build

FROM node:${NODE_VERSION}-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    HOST=0.0.0.0 \
    PORT=3000

RUN groupadd --system --gid 10001 quote \
  && useradd --system --uid 10001 --gid quote --home-dir /app --shell /usr/sbin/nologin quote

COPY --from=deps --chown=quote:quote /app/node_modules ./node_modules
COPY --from=build --chown=quote:quote /app/dist ./dist
COPY --chown=quote:quote package.json package-lock.json ./
COPY --chown=quote:quote scripts ./scripts

USER quote
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["node", "scripts/healthcheck.mjs"]

CMD ["node", "scripts/start-vinext.mjs"]
