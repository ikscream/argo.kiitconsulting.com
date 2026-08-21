# Multi-stage build -> tiny static, non-root, distroless image.
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /echo .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /echo /echo
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/echo"]
