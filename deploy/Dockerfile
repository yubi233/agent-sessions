# Relay 多阶段构建镜像（本地 Compose 用）。
FROM golang:1.26 AS build
# GOPROXY 可按构建环境覆盖：默认官方代理；受限网络（如国内 ECS）构建时传
# --build-arg GOPROXY=https://goproxy.cn,direct，不改变镜像产物内容。
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=${GOPROXY}
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/relay ./apps/relay

FROM scratch
COPY --from=build /out/relay /relay
EXPOSE 8787
ENTRYPOINT ["/relay"]
