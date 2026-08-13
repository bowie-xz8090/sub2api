#!/usr/bin/env bash

# Update an existing Docker Compose deployment from the latest repository code.
# Only the application service is rebuilt and recreated. PostgreSQL, Redis,
# existing bind mounts, named volumes, .env, and config.yaml are preserved.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UPDATE_OVERRIDE="${SCRIPT_DIR}/docker-compose.update.yml"

APP_SERVICE="${APP_SERVICE:-sub2api}"
DB_SERVICE="${DB_SERVICE:-postgres}"
UPDATE_REMOTE="${UPDATE_REMOTE:-origin}"
UPDATE_BRANCH="${UPDATE_BRANCH:-main}"
IMAGE_REPOSITORY="${SUB2API_IMAGE_REPOSITORY:-bowie-xz8090/sub2api}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
SKIP_GIT=false
CREATE_BACKUP=true
ENV_FILE=""
PROJECT_NAME=""
PROJECT_DIRECTORY=""
declare -a COMPOSE_FILES=()

usage() {
    cat <<'EOF'
Usage: deploy/update-existing.sh [options]

Build the latest checked-out source and recreate only the existing sub2api
application container. Existing database/cache containers, volumes, .env, and
config.yaml are not replaced.

Options:
  -f, --compose-file FILE  Existing Compose file; may be repeated.
      --env-file FILE      Existing deployment .env file.
      --project-name NAME  Existing Compose project name.
      --project-dir DIR    Existing Compose project directory.
      --remote NAME        Git remote to update from (default: origin).
      --branch NAME        Git branch to update from (default: main).
      --skip-git           Build the current checkout without git fetch/merge.
      --no-backup          Skip PostgreSQL/config/.env backup.
      --health-timeout N   Health-check timeout in seconds (default: 180).
  -h, --help               Show this help.

When -f is omitted, the script discovers the Compose files and project name
from the existing sub2api container labels.
EOF
}

log() {
    printf '[sub2api-update] %s\n' "$*"
}

fail() {
    printf '[sub2api-update] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

absolute_path() {
    local path="$1"
    local dir
    dir="$(cd "$(dirname "$path")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}

contains_compose_file() {
    local candidate="$1"
    local file
    for file in "${COMPOSE_FILES[@]}"; do
        [[ "$file" == "$candidate" ]] && return 0
    done
    return 1
}

find_existing_app_container() {
    local container_id=""
    container_id="$(docker ps -aq --filter "name=^/${APP_SERVICE}$" | head -n 1)"
    if [[ -z "$container_id" ]]; then
        container_id="$(docker ps -aq --filter "label=com.docker.compose.service=${APP_SERVICE}" | head -n 1)"
    fi
    [[ -n "$container_id" ]] || fail "no existing Compose container found for service '${APP_SERVICE}'"
    printf '%s\n' "$container_id"
}

discover_compose_context() {
    local container_id="$1"
    local raw_files raw_project raw_working_dir file

    raw_project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$container_id")"
    raw_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$container_id")"
    raw_working_dir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container_id")"

    [[ -n "$raw_files" && "$raw_files" != "<no value>" ]] || \
        fail "cannot discover Compose files; pass --compose-file explicitly"

    if [[ -z "$PROJECT_NAME" && -n "$raw_project" && "$raw_project" != "<no value>" ]]; then
        PROJECT_NAME="$raw_project"
    fi
    if [[ -z "$PROJECT_DIRECTORY" && -n "$raw_working_dir" && "$raw_working_dir" != "<no value>" ]]; then
        [[ -d "$raw_working_dir" ]] || fail "discovered Compose project directory no longer exists: $raw_working_dir"
        PROJECT_DIRECTORY="$(cd "$raw_working_dir" && pwd)"
    fi

    IFS=',' read -r -a discovered_files <<< "$raw_files"
    for file in "${discovered_files[@]}"; do
        file="${file#${file%%[![:space:]]*}}"
        file="${file%${file##*[![:space:]]}}"
        [[ -f "$file" ]] || fail "discovered Compose file no longer exists: $file"
        file="$(absolute_path "$file")"
        if ! contains_compose_file "$file"; then
            COMPOSE_FILES+=("$file")
        fi
    done
}

compose_container_id() {
    "${BASE_COMPOSE[@]}" ps -q "$1" | head -n 1
}

container_is_running() {
    local container_id="$1"
    [[ -n "$container_id" ]] && [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == "true" ]]
}

backup_existing_deployment() {
    local app_container="$1"
    local db_container backup_root stamp db_backup

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_root="${BACKUP_DIR:-$(dirname "${COMPOSE_FILES[0]}")/backups/${stamp}}"
    mkdir -p "$backup_root"
    chmod 700 "$backup_root"

    db_container="$(compose_container_id "$DB_SERVICE")"
    container_is_running "$db_container" || fail "database service '${DB_SERVICE}' is not running; use --no-backup only if the database is external"

    db_backup="${backup_root}/postgres.dump"
    log "backing up PostgreSQL to ${db_backup}"
    "${BASE_COMPOSE[@]}" exec -T "$DB_SERVICE" sh -eu -c \
        'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' > "$db_backup"
    [[ -s "$db_backup" ]] || fail "PostgreSQL backup is empty"
    chmod 600 "$db_backup"

    if docker exec "$app_container" sh -c 'test -f /app/data/config.yaml' >/dev/null 2>&1; then
        docker cp "${app_container}:/app/data/config.yaml" "${backup_root}/config.yaml"
        chmod 600 "${backup_root}/config.yaml"
    fi

    if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
        cp -p "$ENV_FILE" "${backup_root}/deployment.env"
        chmod 600 "${backup_root}/deployment.env"
    fi

    printf '%s\n' "$(git -C "$REPO_ROOT" rev-parse HEAD)" > "${backup_root}/previous-source-commit.txt"
    log "backup completed: ${backup_root}"
}

wait_for_application() {
    local deadline container_id status
    deadline=$((SECONDS + HEALTH_TIMEOUT))

    while (( SECONDS < deadline )); do
        container_id="$("${UPDATE_COMPOSE[@]}" ps -q "$APP_SERVICE" | head -n 1)"
        if [[ -n "$container_id" ]]; then
            status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id")"
            case "$status" in
                healthy)
                    return 0
                    ;;
                running)
                    # Compose files without a healthcheck can only expose the
                    # container state. Give the process a short stabilization window.
                    sleep 5
                    [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == "true" ]] && return 0
                    ;;
                unhealthy|exited|dead)
                    return 1
                    ;;
            esac
        fi
        sleep 3
    done
    return 1
}

rollback_application() {
    local rollback_image="$1"
    log "new container did not become healthy; restoring application image ${rollback_image}"
    export SUB2API_UPDATE_IMAGE="$rollback_image"
    "${UPDATE_COMPOSE[@]}" up -d --no-deps --force-recreate "$APP_SERVICE" || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--compose-file)
            [[ $# -ge 2 ]] || fail "$1 requires a file"
            [[ -f "$2" ]] || fail "Compose file not found: $2"
            COMPOSE_FILES+=("$(absolute_path "$2")")
            shift 2
            ;;
        --env-file)
            [[ $# -ge 2 ]] || fail "$1 requires a file"
            [[ -f "$2" ]] || fail "environment file not found: $2"
            ENV_FILE="$(absolute_path "$2")"
            shift 2
            ;;
        --project-name)
            [[ $# -ge 2 ]] || fail "$1 requires a name"
            PROJECT_NAME="$2"
            shift 2
            ;;
        --project-dir)
            [[ $# -ge 2 ]] || fail "$1 requires a directory"
            [[ -d "$2" ]] || fail "Compose project directory not found: $2"
            PROJECT_DIRECTORY="$(cd "$2" && pwd)"
            shift 2
            ;;
        --remote)
            [[ $# -ge 2 ]] || fail "$1 requires a name"
            UPDATE_REMOTE="$2"
            shift 2
            ;;
        --branch)
            [[ $# -ge 2 ]] || fail "$1 requires a name"
            UPDATE_BRANCH="$2"
            shift 2
            ;;
        --skip-git)
            SKIP_GIT=true
            shift
            ;;
        --no-backup)
            CREATE_BACKUP=false
            shift
            ;;
        --health-timeout)
            [[ $# -ge 2 ]] || fail "$1 requires seconds"
            HEALTH_TIMEOUT="$2"
            [[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || fail "health timeout must be a positive integer"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

require_command docker
require_command git
docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
[[ -f "$UPDATE_OVERRIDE" ]] || fail "update override not found: $UPDATE_OVERRIDE"
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "script must run from a Git checkout"

EXISTING_APP_CONTAINER="$(find_existing_app_container)"
if [[ ${#COMPOSE_FILES[@]} -eq 0 ]]; then
    discover_compose_context "$EXISTING_APP_CONTAINER"
fi

if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$EXISTING_APP_CONTAINER")"
fi
[[ -n "$PROJECT_NAME" && "$PROJECT_NAME" != "<no value>" ]] || fail "cannot determine Compose project name; pass --project-name"

if [[ -z "$PROJECT_DIRECTORY" ]]; then
    PROJECT_DIRECTORY="$(dirname "${COMPOSE_FILES[0]}")"
fi

if [[ -z "$ENV_FILE" ]]; then
    candidate_env="$(dirname "${COMPOSE_FILES[0]}")/.env"
    if [[ -f "$candidate_env" ]]; then
        ENV_FILE="$(absolute_path "$candidate_env")"
    fi
fi

BASE_COMPOSE=(docker compose --project-name "$PROJECT_NAME")
BASE_COMPOSE+=(--project-directory "$PROJECT_DIRECTORY")
if [[ -n "$ENV_FILE" ]]; then
    BASE_COMPOSE+=(--env-file "$ENV_FILE")
fi
for file in "${COMPOSE_FILES[@]}"; do
    BASE_COMPOSE+=(-f "$file")
done

if [[ "$SKIP_GIT" != true ]]; then
    if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
        fail "tracked repository changes exist; commit/stash them or use --skip-git"
    fi
    current_branch="$(git -C "$REPO_ROOT" branch --show-current)"
    [[ "$current_branch" == "$UPDATE_BRANCH" ]] || \
        fail "current branch is '${current_branch:-detached}', expected '${UPDATE_BRANCH}'"
    log "updating source from ${UPDATE_REMOTE}/${UPDATE_BRANCH}"
    git -C "$REPO_ROOT" fetch "$UPDATE_REMOTE" "$UPDATE_BRANCH"
    git -C "$REPO_ROOT" merge --ff-only "${UPDATE_REMOTE}/${UPDATE_BRANCH}"
fi

SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
NEW_IMAGE="${IMAGE_REPOSITORY}:local-${SOURCE_COMMIT}"
export SUB2API_UPDATE_IMAGE="$NEW_IMAGE"

UPDATE_COMPOSE=("${BASE_COMPOSE[@]}")
UPDATE_OVERRIDE_ABS="$(absolute_path "$UPDATE_OVERRIDE")"
if ! contains_compose_file "$UPDATE_OVERRIDE_ABS"; then
    UPDATE_COMPOSE+=(-f "$UPDATE_OVERRIDE_ABS")
fi

log "validating existing Compose configuration"
"${UPDATE_COMPOSE[@]}" config --quiet

OLD_CONTAINER="$(compose_container_id "$APP_SERVICE")"
[[ -n "$OLD_CONTAINER" ]] || fail "service '${APP_SERVICE}' is not part of the selected Compose project"
container_is_running "$OLD_CONTAINER" || fail "existing application container is not running"
OLD_IMAGE_ID="$(docker inspect --format '{{.Image}}' "$OLD_CONTAINER")"
ROLLBACK_IMAGE="${IMAGE_REPOSITORY}:rollback-$(date -u +%Y%m%d%H%M%S)"
docker image tag "$OLD_IMAGE_ID" "$ROLLBACK_IMAGE"

log "building ${NEW_IMAGE} from commit ${SOURCE_COMMIT}"
docker build --pull \
    --build-arg "GOPROXY=${GOPROXY:-https://goproxy.cn,direct}" \
    --build-arg "GOSUMDB=${GOSUMDB:-sum.golang.google.cn}" \
    --tag "$NEW_IMAGE" \
    --file "${REPO_ROOT}/Dockerfile" \
    "$REPO_ROOT"

if [[ "$CREATE_BACKUP" == true ]]; then
    backup_existing_deployment "$OLD_CONTAINER"
else
    log "backup skipped by request"
fi

log "recreating only service '${APP_SERVICE}'; database and Redis stay running"
if ! "${UPDATE_COMPOSE[@]}" up -d --no-deps --force-recreate "$APP_SERVICE"; then
    rollback_application "$ROLLBACK_IMAGE"
    fail "Compose failed to recreate the application container"
fi

if ! wait_for_application; then
    "${UPDATE_COMPOSE[@]}" logs --tail=120 "$APP_SERVICE" || true
    rollback_application "$ROLLBACK_IMAGE"
    fail "new application container failed its health check; previous image was restored"
fi

NEW_CONTAINER="$("${UPDATE_COMPOSE[@]}" ps -q "$APP_SERVICE" | head -n 1)"
log "update completed successfully"
log "source commit: $(git -C "$REPO_ROOT" rev-parse HEAD)"
log "image: ${NEW_IMAGE}"
log "container: ${NEW_CONTAINER}"
log "data/config preserved; PostgreSQL and Redis were not recreated"
