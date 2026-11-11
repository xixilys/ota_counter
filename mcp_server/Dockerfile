FROM dart:stable AS build
WORKDIR /src
COPY . /src/mcp_server/
RUN mkdir -p /out \
    && dart compile exe /src/mcp_server/bin/ota_sync_server.dart -o /out/ota-sync

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin ota \
    && mkdir -p /data \
    && chown -R ota:ota /data
COPY --from=build /out/ota-sync /usr/local/bin/ota-sync
USER ota
ENV OTA_SYNC_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 8787
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8787/health || exit 1
ENTRYPOINT ["ota-sync"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8787"]
