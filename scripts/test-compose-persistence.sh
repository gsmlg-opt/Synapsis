#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

project="synapsis-persistence-$(date +%s)-$$"
first="$project-first"
second="$project-second"
compose=(docker compose --file "$PWD/docker-compose.yml" --project-name "$project")

export SECRET_KEY_BASE="$(openssl rand -hex 64)"
export SYNAPSIS_ENCRYPTION_KEY="$(openssl rand -hex 32)"
export SYNAPSIS_CONCORD_DATA_DIR=/app/data/concord
export SYNAPSIS_CONFIG_DIR=/app/data/config
export SYNAPSIS_MEMORY_DIR=/app/data/memory
export SYNAPSIS_WORKSPACE_ROOT=/app/data/workspace
export SYNAPSIS_WORKSPACE_BLOB_DIR=/app/data/blobs

cleanup() {
  docker rm -f "$first" "$second" >/dev/null 2>&1 || true
  "${compose[@]}" down --volumes --rmi local >/dev/null || true
}
trap cleanup EXIT

start() {
  "${compose[@]}" run --detach --no-deps --name "$1" \
    --env SECRET_KEY_BASE --env SYNAPSIS_ENCRYPTION_KEY app >/dev/null
}

rpc() {
  local container=$1
  shift
  docker exec "$container" /app/bin/synapsis rpc "$@"
}

await_ready() {
  local container=$1
  local deadline=$((SECONDS + 60))
  until rpc "$container" '
    port = System.fetch_env!("PORT")
    %Req.Response{status: 200} =
      Req.get!("http://127.0.0.1:#{port}/api/health", retry: false, receive_timeout: 1000)
  ' >/dev/null 2>&1; do
    if (( SECONDS >= deadline )) || [[ $(docker inspect -f '{{.State.Running}}' "$container") != true ]]; then
      docker logs --tail 60 "$container" >&2
      return 1
    fi
    sleep 1
  done
}

mounted_volume() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}' "$1"
}

"${compose[@]}" config --quiet
"${compose[@]}" build app
start "$first"
await_ready "$first"
first_id=$(docker inspect -f '{{.Id}}' "$first")
volume=$(mounted_volume "$first")
[[ $volume == "${project}_app_data" ]]

created=$(rpc "$first" '
  title = "Compose persistence smoke"
  {:ok, _} = Synapsis.AgentConfigs.create(%{name: "compose-smoke"})
  {:ok, memory} =
    Synapsis.Memory.store_semantic(%{title: title, scope: "shared", kind: "fact", summary: title})

  port = System.fetch_env!("PORT")
  %Req.Response{status: 201, body: %{"data" => %{"id" => id, "title" => ^title}}} =
    Req.post!("http://127.0.0.1:#{port}/api/sessions",
      json: %{title: title, provider: "compose-smoke", model: "fixture"}, retry: false)

  IO.puts("session_id=#{id}")
  IO.puts("memory_id=#{memory.id}")
')
session_id=$(sed -n 's/^session_id=//p' <<<"$created")
memory_id=$(sed -n 's/^memory_id=//p' <<<"$created")
[[ $session_id =~ ^[a-f0-9-]{36}$ && $memory_id =~ ^[a-f0-9]{16}$ ]]

docker stop "$first" >/dev/null
docker rm "$first" >/dev/null
start "$second"
await_ready "$second"
[[ $(docker inspect -f '{{.Id}}' "$second") != "$first_id" ]]
[[ $(mounted_volume "$second") == "$volume" ]]

rpc "$second" "
  title = \"Compose persistence smoke\"
  port = System.fetch_env!(\"PORT\")
  %Req.Response{status: 200, body: %{\"data\" => %{\"id\" => \"$session_id\", \"title\" => ^title}}} =
    Req.get!(\"http://127.0.0.1:#{port}/api/sessions/$session_id\", retry: false)
  %{name: \"compose-smoke\"} = Synapsis.AgentConfigs.get_by_name(\"compose-smoke\")
  {:ok, %{summary: ^title}} = Synapsis.Memory.get_semantic(\"$memory_id\")
"
printf 'Same session, TOML Agent and file memory recovered after container recreation.\n'
