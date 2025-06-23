# syntax=docker/dockerfile:1.4

###############################################################################
# 1. Build Dependencies Stage with enhanced caching
###############################################################################
FROM elixir:1.18.3-otp-27-slim AS deps

WORKDIR /app

# Set Mix environment
ENV MIX_ENV=prod

# Install build tools
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      ca-certificates \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Install Hex and Rebar with cache mount
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix local.hex --force \
 && mix local.rebar --force

# Copy dependency files first
COPY mix.exs mix.lock ./

# Fetch and compile dependencies with cache mounts
RUN --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    --mount=type=cache,target=/root/.cache \
    --mount=type=cache,target=/app/_build,sharing=locked \
    mix deps.get --only prod \
 && mix deps.compile

###############################################################################
# 2. Build Stage with build cache
###############################################################################
FROM deps AS build

WORKDIR /app

# Copy source code
COPY lib lib/
COPY config config/
COPY priv priv/

# Install Hex and Rebar in build stage as well
RUN mix local.hex --force && mix local.rebar --force

# Compile and release with cache mount for build artifacts
RUN --mount=type=cache,target=/app/_build,sharing=locked \
    --mount=type=cache,target=/root/.hex \
    --mount=type=cache,target=/root/.mix \
    mix deps.get --only prod \
 && mix compile --warnings-as-errors \
 && mix release --overwrite \
 && cp -r /app/_build/prod/rel/wanderer_kills /app/release

###############################################################################
# 3. Runtime Stage - minimal size
###############################################################################
FROM debian:bookworm-slim AS runtime

WORKDIR /app

# Install runtime dependencies in one layer
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libncurses6 \
      libstdc++6 \
      openssl \
      ca-certificates \
      libgcc-s1 \
      wget \
      procps \
      locales \
 && echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -r app \
 && useradd -r -d /app -s /usr/sbin/nologin -g app app

# Copy release from build stage with proper structure
COPY --from=build --chown=app:app /app/release/. ./

# Runtime configuration
ENV REPLACE_OS_VARS=true \
    HOME=/app \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Metadata
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.version=$VERSION

# Run as non-root
USER app

# Expose port
EXPOSE 4004

# Entry point
ENTRYPOINT ["bin/wanderer_kills"]
CMD ["start"]

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD ["sh", "-c", "wget --no-verbose --tries=1 --spider http://localhost:4004/health || exit 1"] 