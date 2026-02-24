# Build stage
FROM hexpm/elixir:1.18.3-erlang-28.0.1-debian-bookworm-20250113-slim AS build

RUN apt-get update -y && \
    apt-get install -y build-essential git curl unzip && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

# Install Bun for JS bundling
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Install mix deps
COPY mix.exs mix.lock ./
COPY apps/synapsis_core/mix.exs apps/synapsis_core/
COPY apps/synapsis_data/mix.exs apps/synapsis_data/
COPY apps/synapsis_provider/mix.exs apps/synapsis_provider/
COPY apps/synapsis_server/mix.exs apps/synapsis_server/
COPY apps/synapsis_cli/mix.exs apps/synapsis_cli/
COPY apps/synapsis_web/mix.exs apps/synapsis_web/
COPY apps/synapsis_lsp/mix.exs apps/synapsis_lsp/
COPY apps/synapsis_plugin/mix.exs apps/synapsis_plugin/

RUN mix deps.get --only prod
RUN mix deps.compile

# Build JS assets
COPY apps/synapsis_web/package.json apps/synapsis_web/bun.lock* apps/synapsis_web/
RUN cd apps/synapsis_web && bun install --frozen-lockfile 2>/dev/null || bun install

# Copy all source code
COPY config config
COPY apps apps

# Build assets
RUN cd apps/synapsis_web && bun run build 2>/dev/null || true

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
