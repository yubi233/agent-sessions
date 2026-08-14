# Relay 多阶段构建镜像（本地 Compose 用）。
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /out/relay ./apps/relay

FROM scratch
COPY --from=build /out/relay /relay
EXPOSE 8787
ENTRYPOINT ["/relay"]
