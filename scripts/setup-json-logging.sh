#!/bin/bash
# Day 5 — Enable nginx JSON access logging to syslog
#
# Required before Sentinel can receive nginx logs via Azure Monitor Agent.
# Run this after Day 4 setup-nginx.sh has already completed.
#
# What it does:
#   1. Adds a JSON log format to nginx (structured, parseable in KQL)
#   2. Sends access logs to syslog facility=local0 (AMA picks this up)
#   3. Reloads nginx — zero downtime
#
# Usage:
#   VM_IP=$(terraform output -raw vm_public_ip)
#   scp -i .learningsteps_key scripts/setup-json-logging.sh azureuser@${VM_IP}:/tmp/
#   ssh -i .learningsteps_key azureuser@${VM_IP} "sudo bash /tmp/setup-json-logging.sh"

set -euo pipefail

JSON_CONF="/etc/nginx/conf.d/json_logging.conf"

if [ -f "$JSON_CONF" ]; then
    echo "JSON logging already configured — nothing to do."
    exit 0
fi

echo "==> Configuring nginx JSON syslog logging..."

cat > "$JSON_CONF" << 'EOF'
# Structured JSON format — each field is directly queryable in Sentinel KQL
log_format json_combined escape=json
    '{'
    '"time":"$time_iso8601",'
    '"remote_addr":"$remote_addr",'
    '"method":"$request_method",'
    '"uri":"$request_uri",'
    '"status":$status,'
    '"bytes_sent":$bytes_sent,'
    '"http_referer":"$http_referer",'
    '"http_user_agent":"$http_user_agent",'
    '"request_time":$request_time'
    '}';

# Send to syslog via local0 — Azure Monitor Agent is configured to collect this facility
access_log syslog:server=unix:/dev/log,facility=local0,tag=nginx,severity=info json_combined;
EOF

nginx -t && systemctl reload nginx

echo ""
echo "Done. nginx is logging JSON to syslog (facility=local0, tag=nginx)."
echo ""
echo "Verify locally (wait ~30s for first entries):"
echo "  journalctl -t nginx --since '1 min ago'"
echo ""
echo "Verify in Sentinel (wait 3-10 min for first ingestion):"
echo "  Syslog | where ProcessName == 'nginx' | take 5"
