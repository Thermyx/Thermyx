# Small container for hosts that run Docker (Render, Fly.io, Railway, a VPS).
# The host must terminate HTTPS in front of it and supply the secrets as env vars.
FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ./
ENV NODE_ENV=production PORT=8787 STATUS_FILE=/data/status.json
RUN mkdir -p /data && chown node:node /data
VOLUME ["/data"]
EXPOSE 8787
USER node
CMD ["node", "server.js"]
