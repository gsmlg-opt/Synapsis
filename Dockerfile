# Build stage
FROM hexpm/elixir:1.18.4-erlang-28.3-debian-bookworm-20260316-slim AS build

RUN apt-get update -y && \
    apt-get install -y build-essential git curl ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod
# Placeholder secrets for compile/release config evaluation only.
# Override at runtime via docker-compose / orchestration.
ENV SECRET_KEY_BASE=build-only-placeholder-key-that-is-at-least-64-bytes-long-for-phoenix
ENV SYNAPSIS_ENCRYPTION_KEY=build-only-encryption-key-32bytes

# Install mix deps (layer-cached)
COPY mix.exs mix.lock ./
COPY apps/synapsis_agent/mix.exs apps/synapsis_agent/
COPY apps/synapsis_cli/mix.exs apps/synapsis_cli/
COPY apps/synapsis_core/mix.exs apps/synapsis_core/
COPY apps/synapsis_data/mix.exs apps/synapsis_data/
COPY apps/synapsis_mcp/mix.exs apps/synapsis_mcp/
COPY apps/synapsis_provider/mix.exs apps/synapsis_provider/
COPY apps/synapsis_sandbox/mix.exs apps/synapsis_sandbox/
COPY apps/synapsis_server/mix.exs apps/synapsis_server/
COPY apps/synapsis_web/mix.exs apps/synapsis_web/
COPY apps/synapsis_workspace/mix.exs apps/synapsis_workspace/

RUN mix deps.get --only prod
RUN mix deps.compile

# Install JS packages via duskmoon_npm (Phoenix JS comes from deps/ via file:)
COPY package.json package-lock.json ./
COPY apps/synapsis_web/package.json apps/synapsis_web/
COPY packages/hooks/package.json packages/hooks/
RUN mix npm.ci

# Copy application source
COPY config config
COPY apps apps
COPY packages packages

# Build production assets with DuskmoonBundler
WORKDIR /app/apps/synapsis_web
RUN mix assets.deploy
WORKDIR /app

# Compile and build release
RUN mix compile
RUN mix release synapsis

# Runtime stage
FROM debian:bookworm-slim AS runtime

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates ripgrep git && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

# Copy the release from build stage
COPY --from=build /app/_build/prod/rel/synapsis ./

ENV PHX_HOST=localhost
ENV PORT=4657

EXPOSE 4657

CMD ["bin/synapsis", "start"]
