# syntax=docker/dockerfile:1.7
# 网关镜像：前端静态文件（web/ 的 vite 产物）+ nginx 反向代理。
# 构建上下文为仓库根目录：docker build -f deploy/docker/gateway.Dockerfile .
ARG NODE_IMAGE=node:24.18.0-bookworm-slim
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.28-alpine

# FROM 都经 ARG 指定镜像，版本钉在 ARG 默认值里；hadolint 看不穿 ARG，按行忽略 DL3006。
# 前端产物是静态文件，和目标架构无关：编译固定在构建机本机架构上跑（$BUILDPLATFORM），多架构构建时
# arm64 不用在 QEMU 里跑 npm 和 vite，只有下面 nginx 那一层按目标架构。
# hadolint ignore=DL3006,DL3029
FROM --platform=$BUILDPLATFORM ${NODE_IMAGE} AS web
WORKDIR /web
# 前端插槽包入口（导出 install(register)）：web/vite.config.ts 把它给别名 @knowwork/extensions，不传就是开源的空实现。
# 路径是相对构建时的 web 项目根（这里是 /web）的写法：/... 开头的 vite 会接到项目根上。
# cowork 的桌面端插槽包由 deploy/build-gateway-cowork.ps1 先拷到 web/.extensions/desktop-web，随下面 COPY web/ 进镜像。
ARG KNOWWORK_WEB_EXTENSIONS=
ENV KNOWWORK_WEB_EXTENSIONS=${KNOWWORK_WEB_EXTENSIONS}
COPY web/package.json web/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund
COPY web/ ./
RUN npm run build

# hadolint ignore=DL3006
FROM ${NGINX_IMAGE} AS runtime
COPY deploy/gateway/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=web /web/dist /usr/share/nginx/html
# 非 root（nginx-unprivileged 默认 uid 101），监听 8080
EXPOSE 8080
