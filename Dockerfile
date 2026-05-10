FROM erlang:27-alpine AS builder

RUN apk add --no-cache gcc musl-dev make git

WORKDIR /app
COPY rebar.config rebar.lock* ./
RUN rebar3 deps

COPY . .

# Build CLIPS port program (when CLIPS library available)
# RUN cd apps/clips_port && make

# Build production release
RUN rebar3 as prod release

# --- Runtime ---
FROM alpine:3.20

RUN apk add --no-cache libstdc++ ncurses-libs openssl

COPY --from=builder /app/_build/prod/rel/cli_proxy /opt/cli_proxy

WORKDIR /opt/cli_proxy

EXPOSE 8317 8085 1455 54545

ENTRYPOINT ["/opt/cli_proxy/bin/cli_proxy"]
CMD ["foreground"]
