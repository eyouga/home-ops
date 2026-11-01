#!/usr/bin/env bash
# Fetches the vendored Grafana dashboards at pinned revisions and makes them
# load through the kube-prometheus-stack sidecar: the sidecar doesn't resolve
# grafana.com's import inputs (${DS_PROMETHEUS}), so every dashboard gets a
# `datasource` variable defaulting to the chart's Prometheus (uid prometheus).
# To bump one, change its revision here, re-run, and read the diff.
set -euo pipefail
cd "$(dirname "$0")"

# smartctl_exporter and node-exporter ship no dashboards; these are the most
# used grafana.com ones for their metrics. NVIDIA ships its own.
SMARTCTL=https://grafana.com/api/dashboards/22604/revisions/4/download   # SMARTctl Exporter Dashboard
ZFS=https://grafana.com/api/dashboards/24987/revisions/12/download       # ZFS / Overview
DCGM=https://raw.githubusercontent.com/NVIDIA/dcgm-exporter/4.8.4/grafana/dcgm-exporter-dashboard.json

# Applied to all three: drop the import metadata, replace the import input
# with the variable, and pre-select the chart's datasource.
common='
  del(.__inputs, .__elements)
  | walk(if type == "string" then gsub("\\$\\{DS_PROMETHEUS\\}"; "${datasource}") else . end)
  | .templating.list |= (
      if any(.[]; .name == "datasource") then .
      else [{name: "datasource", label: "Data source", type: "datasource", query: "prometheus", refresh: 1, hide: 0}] + .
      end
      | map(if .name == "datasource" then .current = {text: "Prometheus", value: "prometheus"} else . end))
  | .id = null
'

fetch() { curl -fsSL "$1"; }

fetch "$SMARTCTL" | jq "$common" > smartctl.json
fetch "$DCGM" | jq "$common" > dcgm.json
# Its SMART panels find smartctl series by node-exporter's host IP
# (instance=~"192.168.1.80(:port)?"), which is why smartctl-exporter's
# instance is relabelled to <host IP>:<port>.
fetch "$ZFS" | jq "$common" > zfs.json
