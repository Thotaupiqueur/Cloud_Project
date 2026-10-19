#!/bin/sh
set -eu

log() {
  echo "[analytics-setup] $*"
}

retry() {
  attempts=$1
  delay=$2
  shift 2
  n=0
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    sleep "$delay"
  done
}

api() {
  curl -fsS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" -H "Content-Type: application/json" "$@"
}

grafana_ready() {
  curl -fsS "$GRAFANA_URL/api/health" >/dev/null
}

dashboard_ready() {
  api "$GRAFANA_URL/api/dashboards/uid/$DASHBOARD_UID" >/dev/null
}

log "waiting for Grafana"
retry 60 5 grafana_ready

log "waiting for provisioned dashboard"
retry 60 5 dashboard_ready

log "setting home dashboard"
api -X PUT "$GRAFANA_URL/api/org/preferences" -d "{\"homeDashboardUID\":\"$DASHBOARD_UID\"}"
echo

log "setup complete"
