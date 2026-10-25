# Builds the admin dashboard and the web player and serves both with nginx, which also
# reverse-proxies the API.
FROM node:22-bookworm-slim AS admin
WORKDIR /admin
COPY admin/package.json admin/package-lock.json ./
RUN npm ci
COPY admin/ ./
RUN npm run build

FROM node:22-bookworm-slim AS web
WORKDIR /web
COPY web/package.json web/package-lock.json ./
RUN npm ci
# Copy sources explicitly so a host node_modules/ or dist/ never ends up in the build.
COPY web/index.html web/vite.config.ts web/tsconfig.json ./
COPY web/public ./public
COPY web/src ./src
RUN npm run build

FROM nginx:1.27-alpine
COPY infra/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=admin /admin/dist /usr/share/nginx/admin
COPY --from=web /web/dist /usr/share/nginx/web
