# syntax=docker/dockerfile:1
FROM node:24.12-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# nginx-unprivileged: runs as UID 101 on :8080, so it passes runAsNonRoot in K8s.
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /src/dist /usr/share/nginx/html
ENV API_UPSTREAM=http://web:8000
EXPOSE 8080
