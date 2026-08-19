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

# No `VOLUME` instruction here on purpose. Railway manages volumes itself and rejects
# the Docker directive outright ("docker VOLUME is not supported, use Railway Volumes").
# It was never doing any work anyway — the server creates these directories at startup,
# and what makes the data persist is the volume the host mounts at /data, not this file.
EXPOSE 8080

# $PORT, not a hardcoded 8080: hosts assign the port themselves and the server reads
# it from the environment. Checking a fixed port would report the app as unhealthy
# purely because the check was looking in the wrong place.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:${PORT:-8080}/v1/health" || exit 1

CMD ["node", "server.js"]
