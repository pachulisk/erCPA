FROM erlang:28-alpine AS builder

RUN apk add --no-cache gcc musl-dev make git curl

WORKDIR /app
COPY rebar.config rebar.lock* ./
RUN rebar3 deps

COPY . .

# Download and build CLIPS 6.4 source, then compile clips_port
RUN mkdir -p /tmp/clips_build && \
    curl -sL https://sourceforge.net/projects/clipsrules/files/CLIPS/6.40/clips_core_source_640.tar.gz/download \
    | tar xz -C /tmp/clips_build && \
    cd apps/clips_port && make CLIPS_SRC=/tmp/clips_build/clips_core_source_640/core

# Build production release
RUN rebar3 as prod release

# --- Runtime ---
FROM alpine:3.20

RUN apk add --no-cache libstdc++ ncurses-libs openssl

COPY --from=builder /app/_build/prod/rel/cli_proxy /opt/cli_proxy

WORKDIR /opt/cli_proxy

EXPOSE 8317

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost:8317/healthz || exit 1

ENTRYPOINT ["/opt/cli_proxy/bin/cli_proxy"]
CMD ["foreground"]
