# syntax=docker/dockerfile:1
# Multi-stage build for dsh-cloud-relay: compile with the Go 1.26 toolchain,
# then ship a static binary in a minimal Alpine runtime image with CA
# certificates and a non-root user.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/dsh-cloud-relay ./cmd/dsh-cloud-relay

FROM alpine:3.21
RUN apk add --no-cache ca-certificates \
    && adduser -D -u 10001 -H relay
COPY --from=build /out/dsh-cloud-relay /usr/local/bin/dsh-cloud-relay
USER relay
EXPOSE 8090
ENTRYPOINT ["/usr/local/bin/dsh-cloud-relay"]
CMD ["--listen", ":8090"]
