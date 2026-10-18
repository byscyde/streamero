# Builds the admin dashboard and serves it with nginx, which also reverse-proxies the API.
FROM node:22-bookworm-slim AS admin
WORKDIR /admin
COPY admin/package.json admin/package-lock.json ./
RUN npm ci
COPY admin/ ./
RUN npm run build

FROM nginx:1.27-alpine
COPY infra/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=admin /admin/dist /usr/share/nginx/admin
