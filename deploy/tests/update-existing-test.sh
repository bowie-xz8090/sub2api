#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="${TMP_DIR}/bin"
DOCKER_LOG="${TMP_DIR}/docker.log"
COMPOSE_FILE="${TMP_DIR}/docker-compose.yml"
ENV_FILE="${TMP_DIR}/.env"
BACKUP_DIR="${TMP_DIR}/backup"
mkdir -p "$FAKE_BIN"

cat > "$COMPOSE_FILE" <<'YAML'
services:
  sub2api:
    image: old/sub2api:latest
  postgres:
    image: postgres:18-alpine
  redis:
    image: redis:8-alpine
YAML
printf 'POSTGRES_PASSWORD=test-only\n' > "$ENV_FILE"

cat > "${FAKE_BIN}/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$DOCKER_LOG"
printf '\n' >> "$DOCKER_LOG"

case "${1:-}" in
  compose)
    shift
    for arg in "$@"; do
      [[ "$arg" == "version" ]] && exit 0
    done
    if [[ " $* " == *" ps -q sub2api "* ]]; then
      printf 'app-container\n'
    elif [[ " $* " == *" ps -q postgres "* ]]; then
      printf 'postgres-container\n'
    elif [[ " $* " == *" exec -T postgres "* ]]; then
      printf 'fake-postgres-dump\n'
    fi
    exit 0
    ;;
  ps)
    printf 'app-container\n'
    ;;
  inspect)
    case "$*" in
      *'.State.Running'*) printf 'true\n' ;;
      *'.State.Health'*) printf 'healthy\n' ;;
      *'.Image'*) printf 'sha256:old-image\n' ;;
      *'com.docker.compose.project"'*) printf 'sub2api\n' ;;
      *'com.docker.compose.project.config_files'*) printf '%s\n' "$COMPOSE_FILE" ;;
      *'com.docker.compose.project.working_dir'*) printf '%s\n' "$(dirname "$COMPOSE_FILE")" ;;
      *) printf '<no value>\n' ;;
    esac
    ;;
  exec)
    # Report that /app/data/config.yaml exists.
    exit 0
    ;;
  cp)
    printf 'preserved-config\n' > "${3:-$BACKUP_DIR/config.yaml}"
    ;;
  image|build)
    exit 0
    ;;
esac
MOCK
chmod +x "${FAKE_BIN}/docker"

export PATH="${FAKE_BIN}:$PATH"
export DOCKER_LOG COMPOSE_FILE ENV_FILE BACKUP_DIR

output="$({
  cd "$REPO_ROOT"
  BACKUP_DIR="$BACKUP_DIR" \
    "$DEPLOY_DIR/update-existing.sh" \
      --skip-git
} 2>&1)"

grep -q 'update completed successfully' <<< "$output"
grep -q '^compose ' "$DOCKER_LOG"
grep -q 'up -d --no-deps --force-recreate sub2api' "$DOCKER_LOG"
grep -q 'exec -T postgres' "$DOCKER_LOG"
grep -q 'build --pull' "$DOCKER_LOG"
grep -q -- '--project-directory' "$DOCKER_LOG"
grep -q -- "$TMP_DIR" "$DOCKER_LOG"
grep -q 'fake-postgres-dump' "$BACKUP_DIR/postgres.dump"
grep -q 'POSTGRES_PASSWORD=test-only' "$BACKUP_DIR/deployment.env"

if grep -Eq '(^|[[:space:]])down([[:space:]]|$)|volume (rm|prune)|rm -rf' "$DOCKER_LOG"; then
  printf 'unsafe Docker operation detected:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
  exit 1
fi

if grep -Eq 'up .*postgres|force-recreate postgres|up .*redis|force-recreate redis' "$DOCKER_LOG"; then
  printf 'dependency recreation detected:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
  exit 1
fi

printf 'update-existing.sh test passed\n'
