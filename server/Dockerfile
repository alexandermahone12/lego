# Node 22.5+ is required — that is when the built-in node:sqlite arrived.
FROM node:22-alpine

WORKDIR /app

# No dependencies to install, so there is nothing to cache: just the source.
COPY . .

# The database lives on a mounted volume, NOT in the image. Anything written inside
# the container is destroyed on every redeploy — this is the single most common way
# to lose all your listings.
ENV NODE_ENV=production
ENV DATABASE_PATH=/data/bricksouq.db
ENV PORT=8080

VOLUME ["/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/v1/health || exit 1

CMD ["node", "server.js"]
