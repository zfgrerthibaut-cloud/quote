# syntax=docker/dockerfile:1.7

ARG NODE_VERSION=22.13.0

FROM node:${NODE_VERSION}-bookworm-slim AS deps
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:${NODE_VERSION}-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    PORT=8787

RUN groupadd --system --gid 10001 quote \
  && useradd --system --uid 10001 --gid quote --home-dir /app --shell /usr/sbin/nologin quote

COPY --from=deps --chown=quote:quote /app/node_modules ./node_modules
COPY --chown=quote:quote package.json package-lock.json ./
COPY --chown=quote:quote src ./src
COPY --chown=quote:quote migrations ./migrations

USER quote
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["node", "--experimental-strip-types", "src/healthcheck.ts", "api"]

CMD ["node", "--experimental-strip-types", "src/server.ts"]
