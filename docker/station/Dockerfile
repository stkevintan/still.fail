# A disposable still.fail station with the GitHub Copilot runtime, for local experiments.
# Build from the repository root: docker build -f docker/station/Dockerfile -t stillfail-station-copilot .
FROM rust:1-bookworm AS station-load
WORKDIR /src
COPY vendor ./vendor
COPY station/tools/load ./station/tools/load
WORKDIR /src/station/tools/load
RUN cargo build --release --locked

FROM node:24-bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl sqlite3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY station/dist /app/station
COPY docker/station/native/mesh.node /app/station/mesh.node
COPY docker/station/native/stillfail-runner /app/station/stillfail-runner
COPY docker/station/package.json /app/station/package.json
RUN cd /app/station && npm install --omit=dev --ignore-scripts --no-audit --no-fund
COPY docker/station/entrypoint.sh /app/entrypoint.sh
COPY docker/station/gateway.mjs /app/gateway.mjs
COPY --from=station-load /src/station/tools/load/target/release/station-load /usr/local/bin/station-load
RUN chmod +x /app/entrypoint.sh /app/station/mesh.node /app/station/stillfail-runner /usr/local/bin/station-load
ENV STILLFAIL_MESH_NATIVE=/app/station/mesh.node \
    STILLFAIL_RUNNER=/app/station/stillfail-runner \
    DATA=/data \
    PORT=8899 \
    MESH_PORT=4761 \
    GATEWAY_PORT=8080
EXPOSE 8080 8899
ENTRYPOINT ["/app/entrypoint.sh"]
