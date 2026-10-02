# Small container for hosts that run Docker (Render, Fly.io, Railway, a VPS).
# The host must terminate HTTPS and mount a PERSISTENT volume at /data —
# many hosts wipe local files on every redeploy, which would unpair everyone.
FROM node:22-alpine
WORKDIR /app
COPY package.json server.js store.js admin.js ./
ENV NODE_ENV=production PORT=8787 DATABASE_FILE=/data/thermyx.sqlite
RUN mkdir -p /data && chown node:node /data
VOLUME ["/data"]
EXPOSE 8787
USER node
CMD ["node", "--disable-warning=ExperimentalWarning", "server.js"]
