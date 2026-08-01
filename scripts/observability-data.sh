#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/compose.yaml"
PROJECT_NAME="${OBS_PROJECT_NAME:-infra-home-docker}"
BACKUP_ROOT="${OBS_BACKUP_DIR:-$REPO_ROOT/data/backups/observability}"
HELPER_IMAGE="${OBS_DATA_HELPER_IMAGE:-prom/prometheus:latest}"

if [[ "$BACKUP_ROOT" != /* ]]; then
  BACKUP_ROOT="$REPO_ROOT/$BACKUP_ROOT"
fi

COMPOSE=(
  docker compose
  --project-directory "$REPO_ROOT"
  -f "$COMPOSE_FILE"
  -p "$PROJECT_NAME"
)

readonly -a COMPONENTS=(loki prometheus jaeger grafana)
declare -Ar VOLUMES=(
  [loki]="${PROJECT_NAME}_loki-data"
  [prometheus]="${PROJECT_NAME}_prometheus-data"
  [jaeger]="${PROJECT_NAME}_jaeger-data"
  [grafana]="${PROJECT_NAME}_grafana-data"
)
declare -Ar SERVICES=(
  [loki]="loki"
  [prometheus]="prometheus"
  [jaeger]="jaeger"
  [grafana]="grafana"
)

SERVICES_TO_RESTART=()
STAGING_DIR=""

usage() {
  cat <<'EOF'
Observability named volume 관리 도구

사용법:
  observability-data.sh status
  observability-data.sh backup [telemetry|all|loki|prometheus|jaeger|grafana]
  observability-data.sh list-backups
  observability-data.sh restore <backup-id> [telemetry|all|loki|prometheus|jaeger|grafana] [--yes]
  observability-data.sh reset <telemetry|all|loki|prometheus|jaeger|grafana> [--yes]
  observability-data.sh delete-backup <backup-id> [--yes]

대상:
  telemetry  Loki + Prometheus + Jaeger (기본 backup 대상)
  all        telemetry + Grafana

환경 변수:
  OBS_BACKUP_DIR        백업 루트 경로
                        기본값: <repo>/data/backups/observability
  OBS_PROJECT_NAME      Compose project 이름
                        기본값: infra-home-docker
  OBS_DATA_HELPER_IMAGE volume tar/du 작업용 이미지
                        기본값: prom/prometheus:latest

안전 규칙:
  - Registry volume은 어떤 명령에도 포함되지 않습니다.
  - backup은 일관성을 위해 대상 backend와 Collector를 잠시 중지합니다.
  - restore/reset/delete-backup은 대화형 확인 또는 --yes가 필요합니다.
  - restore 전에 현재 데이터를 별도로 backup하는 것을 권장합니다.
EOF
}

die() {
  printf '오류: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[observability-data] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "필수 명령을 찾을 수 없습니다: $1"
}

ensure_prerequisites() {
  require_command docker
  require_command tar
  require_command sha256sum
  require_command awk
  require_command grep
  require_command du
  [[ -f "$COMPOSE_FILE" ]] || die "Compose 파일을 찾을 수 없습니다: $COMPOSE_FILE"
  "${COMPOSE[@]}" config --quiet
  docker info >/dev/null
}

ensure_backup_root() {
  mkdir -p -- "$BACKUP_ROOT"
  BACKUP_ROOT="$(cd -- "$BACKUP_ROOT" && pwd)"
}

expand_target() {
  local target="$1"

  case "$target" in
    telemetry)
      printf '%s\n' loki prometheus jaeger
      ;;
    all)
      printf '%s\n' loki prometheus jaeger grafana
      ;;
    loki|prometheus|jaeger|grafana)
      printf '%s\n' "$target"
      ;;
    *)
      die "지원하지 않는 대상입니다: $target"
      ;;
  esac
}

validate_target() {
  case "$1" in
    telemetry|all|loki|prometheus|jaeger|grafana) ;;
    *) die "지원하지 않는 대상입니다: $1" ;;
  esac
}

append_unique() {
  local -n destination="$1"
  local value="$2"
  local item

  for item in "${destination[@]:-}"; do
    [[ "$item" == "$value" ]] && return
  done
  destination+=("$value")
}

is_telemetry_component() {
  case "$1" in
    loki|prometheus|jaeger) return 0 ;;
    *) return 1 ;;
  esac
}

service_is_running() {
  local service="$1"
  local running

  running="$("${COMPOSE[@]}" ps --status running --services)"
  grep -Fxq -- "$service" <<<"$running"
}

stop_for_components() {
  local -a components=("$@")
  local -a services_to_stop=()
  local component
  local service
  local has_telemetry=false

  SERVICES_TO_RESTART=()

  for component in "${components[@]}"; do
    if is_telemetry_component "$component"; then
      has_telemetry=true
    fi
  done

  if [[ "$has_telemetry" == true ]]; then
    append_unique services_to_stop otel-collector
  fi

  for component in "${components[@]}"; do
    append_unique services_to_stop "${SERVICES[$component]}"
  done

  for service in "${services_to_stop[@]}"; do
    if service_is_running "$service"; then
      SERVICES_TO_RESTART+=("$service")
    fi
  done

  if ((${#services_to_stop[@]} > 0)); then
    log "서비스 중지: ${services_to_stop[*]}"
    "${COMPOSE[@]}" stop "${services_to_stop[@]}"
  fi
}

restart_original_services() {
  if ((${#SERVICES_TO_RESTART[@]} == 0)); then
    return
  fi

  log "기존 실행 상태 복구: ${SERVICES_TO_RESTART[*]}"
  "${COMPOSE[@]}" up -d --no-deps "${SERVICES_TO_RESTART[@]}"
  SERVICES_TO_RESTART=()
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if ((${#SERVICES_TO_RESTART[@]} > 0)); then
    log "중단된 서비스 실행 상태 복구 시도"
    "${COMPOSE[@]}" up -d --no-deps "${SERVICES_TO_RESTART[@]}" >&2 || true
  fi

  if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" && "$STAGING_DIR" == "$BACKUP_ROOT"/.tmp.* ]]; then
    rm -rf -- "$STAGING_DIR"
  fi

  exit "$status"
}

trap cleanup EXIT INT TERM

volume_exists() {
  docker volume inspect "$1" >/dev/null 2>&1
}

ensure_volumes_exist() {
  local component
  local volume

  for component in "$@"; do
    volume="${VOLUMES[$component]}"
    volume_exists "$volume" || die "volume이 없습니다: $volume"
  done
}

ensure_restore_volumes() {
  local component
  local volume

  for component in "$@"; do
    volume="${VOLUMES[$component]}"
    if ! volume_exists "$volume"; then
      log "복원용 volume 생성: $volume"
      "${COMPOSE[@]}" create --no-deps "${SERVICES[$component]}"
      volume_exists "$volume" || die "volume 생성에 실패했습니다: $volume"
    fi
  done
}

archive_volume() {
  local component="$1"
  local archive="$2"
  local volume="${VOLUMES[$component]}"

  log "$component 백업: $volume"
  docker run --rm --user 0 --entrypoint /bin/sh \
    -v "$volume:/source:ro" \
    "$HELPER_IMAGE" \
    -c 'tar -czf - -C /source .' >"$archive"

  tar -tzf "$archive" >/dev/null
}

backup_components() {
  local -a components=("$@")
  local backup_id
  local final_dir
  local component
  local joined_components

  ((${#components[@]} > 0)) || die "백업 대상이 없습니다"
  ensure_backup_root
  ensure_volumes_exist "${components[@]}"

  backup_id="$(date -u +'%Y%m%dT%H%M%SZ')"
  final_dir="$BACKUP_ROOT/$backup_id"
  if [[ -e "$final_dir" ]]; then
    backup_id="${backup_id}-$$"
    final_dir="$BACKUP_ROOT/$backup_id"
  fi

  STAGING_DIR="$(mktemp -d "$BACKUP_ROOT/.tmp.XXXXXX")"
  stop_for_components "${components[@]}"

  for component in "${components[@]}"; do
    archive_volume "$component" "$STAGING_DIR/$component.tar.gz"
  done

  joined_components="$(IFS=,; printf '%s' "${components[*]}")"
  {
    printf 'format_version=1\n'
    printf 'created_at_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'project_name=%s\n' "$PROJECT_NAME"
    printf 'components=%s\n' "$joined_components"
    for component in "${components[@]}"; do
      printf 'volume_%s=%s\n' "$component" "${VOLUMES[$component]}"
    done
  } >"$STAGING_DIR/manifest.env"

  (
    cd -- "$STAGING_DIR"
    sha256sum ./*.tar.gz >SHA256SUMS
  )

  restart_original_services
  mv -- "$STAGING_DIR" "$final_dir"
  STAGING_DIR=""

  log "백업 완료: $final_dir"
  printf '%s\n' "$backup_id"
}

status_command() {
  local component
  local volume
  local size
  local state

  printf '%-12s %-42s %-10s %s\n' COMPONENT VOLUME SIZE SERVICE
  for component in "${COMPONENTS[@]}"; do
    volume="${VOLUMES[$component]}"
    if volume_exists "$volume"; then
      size="$(docker run --rm --user 0 --entrypoint /bin/sh \
        -v "$volume:/data:ro" "$HELPER_IMAGE" -c 'du -sh /data' | awk '{print $1}')"
    else
      size="missing"
    fi

    if service_is_running "${SERVICES[$component]}"; then
      state="running"
    else
      state="stopped"
    fi

    printf '%-12s %-42s %-10s %s\n' "$component" "$volume" "$size" "$state"
  done

  printf '\nbackup root: %s\n' "$BACKUP_ROOT"
}

list_backups_command() {
  local -a directories=()
  local directory
  local components
  local created_at
  local size

  ensure_backup_root
  shopt -s nullglob
  for directory in "$BACKUP_ROOT"/*; do
    [[ -d "$directory" ]] && directories+=("$directory")
  done
  shopt -u nullglob

  if ((${#directories[@]} == 0)); then
    log "백업이 없습니다: $BACKUP_ROOT"
    return
  fi

  printf '%-24s %-22s %-38s %s\n' BACKUP_ID CREATED_AT COMPONENTS SIZE
  for directory in "${directories[@]}"; do
    created_at="-"
    components="-"
    if [[ -f "$directory/manifest.env" ]]; then
      created_at="$(awk -F= '$1 == "created_at_utc" {print $2}' "$directory/manifest.env")"
      components="$(awk -F= '$1 == "components" {print $2}' "$directory/manifest.env")"
    fi
    size="$(du -sh "$directory" | awk '{print $1}')"
    printf '%-24s %-22s %-38s %s\n' "$(basename -- "$directory")" "$created_at" "$components" "$size"
  done
}

validate_backup_id() {
  local backup_id="$1"
  [[ "$backup_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "잘못된 backup-id입니다: $backup_id"
}

validate_archive() {
  local backup_dir="$1"
  local component="$2"
  local archive="$backup_dir/$component.tar.gz"
  local entry

  [[ -f "$archive" ]] || die "백업에 $component archive가 없습니다: $archive"

  if [[ -f "$backup_dir/SHA256SUMS" ]]; then
    (
      cd -- "$backup_dir"
      sha256sum --check --ignore-missing SHA256SUMS >/dev/null
    ) || die "백업 checksum 검증에 실패했습니다: $backup_dir"
  fi

  tar -tzf "$archive" >/dev/null || die "archive 검사에 실패했습니다: $archive"

  while IFS= read -r entry; do
    case "$entry" in
      /*|..|../*|*/../*|*/..)
        die "안전하지 않은 archive 경로입니다: $entry"
        ;;
    esac
  done < <(tar -tzf "$archive")
}

confirm_destructive() {
  local action="$1"
  local expected="$2"
  local assume_yes="$3"
  local answer

  if [[ "$assume_yes" == true ]]; then
    return
  fi

  [[ -t 0 ]] || die "$action 작업에는 --yes가 필요합니다"
  printf '%s 작업은 기존 데이터를 덮어쓰거나 삭제합니다.\n' "$action" >&2
  printf '계속하려면 "%s"를 입력하세요: ' "$expected" >&2
  read -r answer
  [[ "$answer" == "$expected" ]] || die "취소되었습니다"
}

clear_and_restore_volume() {
  local component="$1"
  local archive="$2"
  local volume="${VOLUMES[$component]}"

  log "$component 복원: $volume"
  docker run --rm -i --user 0 --entrypoint /bin/sh \
    -v "$volume:/target" \
    "$HELPER_IMAGE" \
    -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && tar -xzf - -C /target' \
    <"$archive"
}

restore_command() {
  local backup_id="$1"
  local target="${2:-}"
  local assume_yes="$3"
  local backup_dir
  local component
  local -a components=()

  ensure_backup_root
  validate_backup_id "$backup_id"
  backup_dir="$BACKUP_ROOT/$backup_id"
  [[ -d "$backup_dir" ]] || die "백업을 찾을 수 없습니다: $backup_dir"

  if [[ -n "$target" ]]; then
    validate_target "$target"
    mapfile -t components < <(expand_target "$target")
  else
    for component in "${COMPONENTS[@]}"; do
      [[ -f "$backup_dir/$component.tar.gz" ]] && components+=("$component")
    done
  fi
  ((${#components[@]} > 0)) || die "복원할 archive가 없습니다: $backup_dir"

  for component in "${components[@]}"; do
    validate_archive "$backup_dir" "$component"
  done
  ensure_restore_volumes "${components[@]}"
  confirm_destructive "restore $backup_id" "$backup_id" "$assume_yes"

  stop_for_components "${components[@]}"
  for component in "${components[@]}"; do
    clear_and_restore_volume "$component" "$backup_dir/$component.tar.gz"
  done
  restart_original_services
  log "복원 완료: $backup_id"
}

clear_volume() {
  local component="$1"
  local volume="${VOLUMES[$component]}"

  if ! volume_exists "$volume"; then
    log "volume이 없어 건너뜁니다: $volume"
    return
  fi

  log "$component 초기화: $volume"
  docker run --rm --user 0 --entrypoint /bin/sh \
    -v "$volume:/target" \
    "$HELPER_IMAGE" \
    -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
}

reset_command() {
  local target="$1"
  local assume_yes="$2"
  local component
  local -a components=()

  validate_target "$target"
  mapfile -t components < <(expand_target "$target")
  confirm_destructive "reset $target" "$target" "$assume_yes"

  stop_for_components "${components[@]}"
  for component in "${components[@]}"; do
    clear_volume "$component"
  done
  restart_original_services
  log "초기화 완료: $target"
}

delete_backup_command() {
  local backup_id="$1"
  local assume_yes="$2"
  local backup_dir

  ensure_backup_root
  validate_backup_id "$backup_id"
  backup_dir="$BACKUP_ROOT/$backup_id"
  [[ -d "$backup_dir" ]] || die "백업을 찾을 수 없습니다: $backup_dir"
  confirm_destructive "delete-backup $backup_id" "$backup_id" "$assume_yes"

  rm -rf -- "$backup_dir"
  log "백업 삭제 완료: $backup_id"
}

main() {
  local -a arguments=()
  local argument
  local command
  local assume_yes=false
  local target
  local backup_id
  local -a components=()

  for argument in "$@"; do
    if [[ "$argument" == "--yes" ]]; then
      assume_yes=true
    else
      arguments+=("$argument")
    fi
  done

  command="${arguments[0]:-help}"
  if [[ "$command" == "help" || "$command" == "--help" || "$command" == "-h" ]]; then
    usage
    return
  fi

  ensure_prerequisites

  case "$command" in
    status)
      ((${#arguments[@]} == 1)) || die "status에는 추가 인자가 없습니다"
      status_command
      ;;
    backup)
      ((${#arguments[@]} <= 2)) || die "backup 인자가 너무 많습니다"
      target="${arguments[1]:-telemetry}"
      validate_target "$target"
      mapfile -t components < <(expand_target "$target")
      backup_components "${components[@]}"
      ;;
    list-backups|backups)
      ((${#arguments[@]} == 1)) || die "list-backups에는 추가 인자가 없습니다"
      list_backups_command
      ;;
    restore)
      ((${#arguments[@]} >= 2 && ${#arguments[@]} <= 3)) || die "restore <backup-id> [target] 형식으로 실행하세요"
      backup_id="${arguments[1]}"
      target="${arguments[2]:-}"
      restore_command "$backup_id" "$target" "$assume_yes"
      ;;
    reset)
      ((${#arguments[@]} == 2)) || die "reset <target> 형식으로 실행하세요"
      target="${arguments[1]}"
      reset_command "$target" "$assume_yes"
      ;;
    delete-backup)
      ((${#arguments[@]} == 2)) || die "delete-backup <backup-id> 형식으로 실행하세요"
      backup_id="${arguments[1]}"
      delete_backup_command "$backup_id" "$assume_yes"
      ;;
    *)
      usage >&2
      die "지원하지 않는 명령입니다: $command"
      ;;
  esac
}

main "$@"
