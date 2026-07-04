# Day 5 — Session Handbook (Sentinel monitoring, adapted log pipeline)

Full pipeline (forwarder -> Syslog -> KQL aggregation -> Sentinel incident ->
automation rule -> Logic App NSG block) was tested end-to-end against a live
Azure deployment during this migration. Two real bugs were found and fixed
along the way (see Troubleshooting) — the KQL in `sentinel.tf` and the
forwarder in `scripts/setup-json-logging.sh` both changed as a result.

## Ordered steps

1. Confirm the forwarder is running on the VM (installed by `deploy.py` ->
   `setup-json-logging.sh` during baseline):
   ```
   sudo systemctl status npmplus-log-forwarder --no-pager
   ```
2. Generate some normal traffic, confirm local syslog capture:
   ```
   curl -s https://<domain>/entries >/dev/null
   journalctl -t nginx --since '1 min ago'
   ```
   Expect JSON lines like `{"time": "...", "seq": 1783164989.85, "remote_addr":
   "...", "domain": "...", "method": "GET", "uri": "/entries", "status": 200,
   "bytes_sent": ...}`.
3. Confirm ingestion into Log Analytics (took ~3-5 min in testing after first
   traffic):
   ```
   Syslog | where ProcessName == "nginx" | take 5
   ```
   in the Sentinel/Log Analytics "Logs" blade
   (`sentinel_portal_url` terraform output links directly to the workspace).
4. Fire the WAF-attack simulation (mirrors the existing "Final Test" slide) —
   **must be run unauthenticated, or with a valid oauth2-proxy session cookie
   if Day 2's Auth Request is already wired on this host** (see Day 4
   handbook's auth-vs-WAF-ordering note):
   ```
   for i in $(seq 1 6); do
     curl -s -o /dev/null -w "%{http_code}\n" \
       "https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users"
   done
   ```
   6 requests in quick succession, all expected `403` (WAF must already be
   enabled from Day 4). Confirmed working in testing.
5. Run the analytics rule's KQL manually first to confirm rows appear before
   waiting on the scheduled rule — **use this exact query** (see
   Troubleshooting for why the originally-planned query didn't work):
   ```kql
   Syslog
   | where ProcessName == "nginx"
   | extend log = parse_json(SyslogMessage)
   | extend StatusCode = toint(log.status)
   | extend ClientIP   = tostring(log.remote_addr)
   | where StatusCode == 403
   | summarize WafBlocks = count() by ClientIP
   | where WafBlocks >= 5
   ```
   Confirmed in testing: returned `77.125.97.10, 7` (7 total 403s accumulated
   across two attack runs during testing).
6. Wait for the scheduled analytics rule (`PT5M`/`PT5M`) to fire -> check
   Sentinel Incidents blade for a new "WAF Attack — High Volume 403s from
   Single IP" incident.
7. Confirm the automation rule triggered the Logic App playbook -> check the
   NSG (`nsg-<prefix>`) for a new Deny rule for the attacker's IP:
   ```
   az network nsg rule list --resource-group <rg> --nsg-name nsg-<prefix> -o table
   ```
   **Then actually verify the block works** — don't just check the rule
   exists (see the priority bug below): from the blocked IP, confirm
   `curl`/`ssh` to the VM now time out at the network level, not just get an
   app-level 403.

## Timing

- Steps 1-3: ~5 min in testing (AMA ingestion latency; real Azure behavior,
  unaffected by this migration).
- Steps 4-7: ~10-20 min (5-minute scheduled rule window + a few minutes of
  Logic App execution latency). Good discussion point while waiting: what
  other signals could feed this pipeline (CrowdSec's own alert stream via
  `cscli alerts list -o json` piped to syslog — noted as a documented future
  enhancement, not implemented in this migration, since nginx access-log
  status codes alone were sufficient to reproduce the existing detection).

## Troubleshooting (all real errors hit during this migration's testing)

- **NPMplus's access.log is NOT Apache/nginx "combined" format**: it's a
  custom format —
  `[time] domain remote_addr response_time "METHOD uri PROTO" status bytes_sent request_length referer user_agent`
  (no leading IP, no `- -` fields, domain comes before the address). An
  initial version of the forwarder assumed combined format and silently
  produced zero JSON output because its regex never matched anything. Fixed
  with a dedicated regex in `scripts/setup-json-logging.sh` matching the real
  format — verify locally with `journalctl -t nginx` before trusting Sentinel
  ingestion; an empty local log is a much faster signal than waiting 10
  minutes for Sentinel to show nothing.
- **The original KQL (`SyslogMessage contains "nginx"` +
  `extract(@'nginx: (\{.*\})', ...)`) returns zero rows against the NPMplus
  pipeline**: this regex assumed the whole syslog line (including the
  `nginx:` tag) landed in `SyslogMessage`. In practice, AMA/rsyslog already
  parses the tag into its own `ProcessName` column, and `SyslogMessage`
  contains only the JSON body with no `nginx:` prefix at all — confirmed by
  directly querying `Syslog | where ProcessName == "nginx" | project
  SyslogMessage`. Fixed in `sentinel.tf`: filter on `ProcessName == "nginx"`
  and `parse_json(SyslogMessage)` directly, no regex needed. This is simpler
  than the original query, not just different.
- **systemd-journald collapses repeated identical log lines**, which silently
  broke the "5+ 403s" count: firing 6 identical attack payloads in under a
  second produced only 2 `Syslog` rows in testing — one normal row and one
  `"message repeated 5 times: [ {...}]"` row (a journald anti-flood feature).
  A naive `parse_json(SyslogMessage)` fails on that wrapper text and the
  `count()` undercounts real attack volume. Fixed by having the forwarder
  include a `"seq"` field (`time.time()`, microsecond precision) in every
  JSON line so consecutive attack requests are never byte-identical and never
  get collapsed. Confirmed fixed: after this change, 6 rapid identical
  requests produced 6 distinct `journalctl -t nginx` lines and 6 distinct
  `Syslog` rows in Log Analytics.
- **If `az sentinel incident list` shows nothing after 5+ minutes**: check
  that the analytics rule was actually re-deployed after any KQL change —
  `terraform apply` updates the rule definition immediately, but it only
  affects the *next* scheduled run (`query_frequency = PT5M`), not
  retroactively. Also double check the rule's `trigger_threshold = 0` with
  `trigger_operator = "GreaterThan"` means "fires on any non-empty result
  set" — if the KQL itself returns zero rows (e.g. because of either bug
  above), the rule will never trigger no matter how long you wait, with no
  error surfaced anywhere obvious. Always validate the raw KQL manually in
  the Logs blade first (step 5) before troubleshooting the scheduled rule itself.
- **MOST IMPORTANT FINDING — the auto-block NSG rule was silently a no-op**:
  the playbook (`templates/block-ip-playbook.json`) originally created its
  `sentinel-block-<ip>` Deny rule at priority `200`. `network.tf`'s baseline
  `allow-ssh`/`allow-http`/`allow-https` rules were at priority `100`/`110`/
  `120` with `source_address_prefix = "*"`. Azure NSGs evaluate rules in
  ascending priority order and stop at the first match — so for literally
  every port the attacker was actually using (22/80/443), the lower-numbered
  `allow-*` rule always matched first and the deny rule at 200 was **never
  even evaluated**. Confirmed by testing: after the full pipeline "worked"
  (incident created, NSG rule visibly added), the supposedly-blocked IP could
  still `curl` the app (got the app/WAF's own 403, not a network timeout) and
  still `ssh` into the VM successfully. The rule existing is not the same as
  the rule doing anything — **always test the actual block**, not just its
  presence. Fixed in this migration: baseline `allow-*` rules moved to
  priority `1000`/`1010`/`1020`, playbook's deny rule moved to priority `100`
  (Azure NSG priorities must be in the range 100-4096; you cannot go lower
  than 100 to "beat" an existing 100-priority rule — the existing rules have
  to move instead). Re-verify after any NSG rule changes on this project:
  `az network nsg rule list` showing the deny rule is necessary but not
  sufficient evidence that blocking works.
- **CrowdSec's own IP-level ban vs. per-request AppSec blocks are two
  different things**: after enough WAF rule matches, CrowdSec creates an
  actual ban *decision* for the source IP (`docker exec crowdsec cscli
  decisions list`), which then blocks **all** subsequent requests from that
  IP for the decision's duration (multiple hours by default) — not just
  requests matching an attack signature. If a "clean" request from a
  previously-attacking IP still gets `403`, check `cscli decisions list`
  before assuming the WAF is misconfigured; the IP may simply be banned
  outright, which is CrowdSec working as intended.
