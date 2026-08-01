# Observability stack

애플리케이션과 분리된 로컬 OpenTelemetry 관측 인프라입니다.

## 구성

- OpenTelemetry Collector: OTLP trace, metric, log 수신
- Jaeger: trace 저장 및 조회
- Jaeger Monitor: span에서 파생한 RED(request, error, duration) metric 조회
- Prometheus: Collector가 노출한 metric scrape
- Loki: OTLP log 저장 및 조회
- Grafana: spanmetrics 백분위 비교, Loki 로그, custom/business metric, Collector 상태와 alert 조회

루트에서 전체 인프라와 함께 실행합니다.

```bash
docker compose up -d
```

관측 서비스만 실행할 수도 있습니다.

```bash
docker compose up -d loki jaeger otel-collector prometheus grafana
```

## 애플리케이션 endpoint

- 호스트 프로세스: `http://localhost:4318`
- 같은 Compose 프로젝트의 컨테이너: `http://otel-collector:4318`
- OTLP/gRPC가 필요한 경우 각각 `localhost:4317`, `otel-collector:4317`

OTLP/HTTP base endpoint에는 `/v1/traces` 등을 붙이지 않습니다. 신호별 endpoint 환경 변수를 사용할 때만 전체 경로를 사용합니다.

## 데이터

Loki, Prometheus, Jaeger, Grafana 데이터는 Docker named volume에 보존됩니다.

| 서비스 | named volume | 컨테이너 경로 |
| --- | --- | --- |
| Loki | `infra-home-docker_loki-data` | `/loki` |
| Prometheus | `infra-home-docker_prometheus-data` | `/prometheus` |
| Jaeger Badger | `infra-home-docker_jaeger-data` | `/badger` |
| Grafana | `infra-home-docker_grafana-data` | `/var/lib/grafana` |

Jaeger trace의 기본 보존 기간은 7일이며 `JAEGER_SPAN_STORE_TTL` 환경 변수로 변경할 수 있습니다.

```bash
docker volume ls --filter label=com.docker.compose.project=infra-home-docker
docker system df -v
```

## 데이터 관리 스크립트

저장소 루트에서 `scripts/observability-data.sh`를 사용해 volume 상태, 백업, 복원과 초기화를 관리합니다.

```bash
# volume 크기와 서비스 상태
./compose-services/observability/scripts/observability-data.sh status

# Loki + Prometheus + Jaeger 백업
./compose-services/observability/scripts/observability-data.sh backup telemetry

# Grafana까지 포함한 백업
./compose-services/observability/scripts/observability-data.sh backup all

# 백업 목록
./compose-services/observability/scripts/observability-data.sh list-backups
```

백업은 기본적으로 `data/backups/observability/<UTC backup-id>/`에 생성되며 Git에서 제외됩니다. 각 volume의 `tar.gz`, `manifest.env`, `SHA256SUMS`가 함께 저장됩니다. 일관된 snapshot을 위해 대상 backend와 Collector를 잠시 중지하고, 작업 전에 실행 중이던 서비스만 다시 실행합니다.

복원과 초기화는 기존 데이터를 덮어쓰거나 삭제하므로 대화형 확인이 필요합니다. CI처럼 입력할 수 없는 환경에서만 `--yes`를 명시합니다.

```bash
# backup-id에 포함된 모든 archive 복원
./compose-services/observability/scripts/observability-data.sh restore 20260730T112923Z

# Jaeger만 복원
./compose-services/observability/scripts/observability-data.sh restore 20260730T112923Z jaeger

# telemetry 전체 초기화
./compose-services/observability/scripts/observability-data.sh reset telemetry

# 오래된 백업 삭제
./compose-services/observability/scripts/observability-data.sh delete-backup 20260730T112923Z
```

`telemetry`는 Loki, Prometheus, Jaeger이고 `all`은 Grafana까지 포함합니다. Registry volume은 어떤 명령에도 포함되지 않습니다. 전체 사용법은 다음 명령으로 확인합니다.

```bash
./compose-services/observability/scripts/observability-data.sh help
```

## 설정 파일

- `otelcol/config.yaml`: receiver, processor, exporter, pipeline
- `prometheus/prometheus.yml`: scrape target
- `loki/config.yml`: single-node filesystem 저장
- `grafana/provisioning/`: datasource, dashboard, alert provisioning
- `grafana/dashboards/elysia-observability.json`: 기존 Elysia 예제 dashboard

공용 dashboard 상단의 `서비스` 변수는 spanmetrics의 `service_name` 값을 자동으로 읽습니다. 앱마다 `OTEL_SERVICE_NAME`을 고유하게 지정하면 별도 dashboard 파일을 만들지 않아도 여러 서비스를 선택하거나 동시에 볼 수 있습니다. 선택한 값은 namespace가 붙을 수 있는 Prometheus `exported_job`과 Loki의 `service_name` 필터에 함께 적용됩니다. `All`은 Loki stream selector 제약에 맞춰 빈 문자열을 제외하는 `.+` 정규식으로 치환됩니다.

새 앱을 연결할 때는 `../../docs/llm/observability/README.md`가 아니라 저장소 루트의 `docs/llm/observability/README.md`를 기준으로 사용합니다.

## Jaeger SPM

Collector의 `spanmetrics` connector가 trace에서 다음 Prometheus metric을 생성합니다.

- `traces_span_metrics_calls_total`
- `traces_span_metrics_duration_milliseconds_bucket`

Jaeger는 Prometheus에서 이 RED metric을 조회해 <http://localhost:16686/monitor>에 서비스별 요청률, 오류율, 지연시간을 표시합니다. `server` span kind가 없는 operation은 Monitor 기본 조회에서 보이지 않을 수 있습니다.

요청률, 오류율, P95와 trace drill-down은 Jaeger Monitor를 기본 화면으로 사용합니다. 현재 Jaeger operation 표는 P95만 표시하므로 Grafana에는 같은 spanmetrics histogram에서 계산하는 P50/P75/P95 비교 패널 하나를 둡니다. 이 패널은 평균값이 아니며, `All`에서도 서비스와 endpoint별 시계열을 분리합니다. 나머지 Grafana panel은 로그, custom error metric, Collector 상태를 보완합니다.

서비스와 endpoint 수에 따라 범례 항목이 늘어나는 `엔트포인트 최대 처리시간`과 `P50/P75/P95` panel은 범례를 오른쪽에 배치하고 너비를 Grafana가 자동 계산하게 둡니다. 현재 Grafana 12.3.3의 dashboard schema에는 최신 문서의 legend item limit과 series visibility filter가 없으므로 지원하지 않는 option을 미리 넣지 않습니다.

현재 `jaegertracing/all-in-one` 이미지는 Jaeger v1 계열이며 EOL 상태입니다. 이 로컬 구성의 SPM을 먼저 활성화한 것이며, 장기 운영 전에는 `jaegertracing/jaeger` v2 구성 파일 방식으로 마이그레이션해야 합니다.

## 보안 범위

기본 구성은 신뢰할 수 있는 로컬 네트워크용이며 OTLP receiver와 backend port에 인증이 없습니다. 인터넷에 직접 공개하지 마세요. 외부 전송이 필요하면 TLS, 인증, 방화벽 또는 사설 네트워크를 먼저 구성합니다.
