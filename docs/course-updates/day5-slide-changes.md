# Day 5 — Slide Changes (log pipeline adapts to NPMplus)

## What's different

Day 5's pipeline (nginx access logs -> syslog -> AMA -> DCR -> Log Analytics
-> Sentinel analytics rule -> Logic App auto-block) is conceptually
**unchanged**, but three concrete things underneath it changed, all
discovered by actually testing the pipeline end-to-end rather than assuming
the old design would carry over:

1. How logs get from "nginx" onto the host's syslog (NPMplus runs nginx in a
   container).
2. NPMplus's access log format itself (not Apache/nginx "combined" format).
3. The Sentinel KQL query (the old regex-based extraction never matches the
   new pipeline's log shape, and journald's own message deduplication
   silently undercounts rapid repeated attack requests unless handled).

### Investigation finding 1 — getting logs out of a container

NPMplus does **not** support a JSON log format or syslog output natively.
With `LOGROTATE=true` (already set in `compose.yaml` by `setup-npmplus.sh`),
NPMplus writes access logs to `/opt/npmplus/nginx/logs/access.log` on the
**host** filesystem (bind-mounted out of the container's `/data` volume).
There's no config toggle to point this at syslog directly.

The fix: a small host-side systemd service (`npmplus-log-forwarder.service`,
installed by the rewritten `scripts/setup-json-logging.sh`) tails
`access.log`, converts each line to JSON, and forwards it to syslog via
`logger -p local0.info -t nginx`.

### Investigation finding 2 — NPMplus's access log format is not what you'd expect

Confirmed by inspecting real log output — NPMplus's format is:
```
[04/Jul/2026:11:26:55 +0000] npmplustest.example.com 77.125.97.10 0.001 "GET /entries HTTP/2.0" 302 116 363 - curl/8.7.1
 ^time                        ^domain                 ^addr        ^rt   ^request                ^status ^bytes  ^len ^ref ^ua
```
This is NOT Apache/nginx "combined" format (no leading IP, no `- -` fields,
domain comes before the address). A parser written against the assumed
combined format would silently produce zero output. The forwarder's regex
was written against this real, confirmed format instead.

### Investigation finding 3 — the KQL query itself needed rework, not just a log-shape footnote

Two real, separate bugs were found and fixed in the Sentinel analytics rule's
KQL (`azurerm_sentinel_alert_rule_scheduled "waf_attack"` in `sentinel.tf`):

- The old query assumed the whole syslog line (`nginx: {json}`) landed in
  `SyslogMessage` and extracted the JSON with a regex. In practice AMA/rsyslog
  already parses the `nginx:` tag into its own `ProcessName` column, and
  `SyslogMessage` contains *only* the JSON body. The regex never matched;
  the query returned zero rows, no error, no obvious signal anything was
  wrong. **New query**: filter on `ProcessName == "nginx"` and
  `parse_json(SyslogMessage)` directly — simpler than before, not just
  different.
- `systemd-journald` collapses repeated identical log lines into a single
  `"message repeated N times: [...]"` entry. Firing 6 identical SQLi payloads
  in under a second (exactly the "Final Test" demo) produced only 2 real
  `Syslog` rows during testing, undercounting the attack. Fixed by having the
  forwarder include a microsecond-precision `"seq"` field in every JSON line
  so consecutive identical-looking requests are never byte-identical.

## Concrete slide edits

1. **Remove**: the old "nginx writes JSON straight to syslog via
   `access_log syslog:server=unix:/dev/log,...`" slide/diagram — that
   directive doesn't exist inside a Docker container without extra plumbing,
   and NPMplus doesn't expose it as a config option anyway.

2. **Add new slide**: "Getting logs out of a container" — a short, generally
   useful lesson (works for any containerized app, not just NPMplus):
   - Option A (chosen here): bind-mount the log directory to the host, run a
     tiny forwarder service on the host. Simple, no extra containers, easy to
     debug (`journalctl -u npmplus-log-forwarder -f`).
   - Option B (mentioned, not implemented): Docker's built-in `syslog`
     logging driver — would work for container *stdout*, but NPMplus's
     access logs are written to a file inside the container, not stdout, so
     this alone wouldn't have worked without also changing NPMplus's
     internal logging target — one more "read what the tool actually does
     before assuming" moment for students.

3. **Update the KQL slide** with the new query (shown above) and add a short
   callout on the journald-deduplication finding — it's a great, concrete
   "why does my count look wrong" lesson that generalizes well beyond this
   course (anyone piping repeated log lines through syslog will hit this).

4. **Update the "Final Test" slide's attack commands** — same payloads, now
   against NPMplus+CrowdSec instead of nginx+ModSecurity, and note that if
   Day 2's oauth2-proxy Auth Request is already wired on this host, the
   payloads must be sent authenticated (see Day 4's ordering note) or they'll
   just redirect to login instead of exercising the WAF:
   ```
   for i in $(seq 1 6); do
     curl -s -o /dev/null -w "%{http_code}\n" \
       "https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users"
   done
   ```

5. **Add new slide — "the auto-block rule existed but didn't block anything"**
   (this is the single most important finding from testing this migration and
   deserves its own slide, independent of the NPMplus switch): the "Final
   Test" originally just checked that an NSG Deny rule for the attacker's IP
   appeared. Testing showed that checking for existence isn't enough — Azure
   NSGs evaluate rules by ascending priority number and stop at the first
   match, so the auto-block rule (originally priority 200) was silently
   overridden by the baseline `allow-ssh`/`allow-http`/`allow-https` rules
   (priority 100/110/120, source `*`), which always matched first. The
   "blocked" IP could still reach the app and SSH into the VM. Fixed by
   moving the baseline allow rules to priority 1000+ and the auto-block rule
   to priority 100. Update the Final Test slide to require an actual
   connectivity check post-block (`curl`/`ssh` should now time out, not just
   return an app-level error) — "the rule exists" and "the rule works" are
   different claims, and this is a genuinely good general lesson about NSG
   priority ordering, not just a footnote.

## Timing

No change to the Sentinel-side scheduling (`PT5M`/`PT5M`, same as before).
Confirmed in testing: AMA ingestion latency was ~3-5 minutes from first
traffic to first `Syslog` row appearing — faster than the original
architecture's typical 3-10 minutes, though this is likely incidental (same
AMA extension, same DCR) rather than anything this migration changed
deliberately. Add ~1 extra minute of live-demo time to show `journalctl -t
nginx` locally on the VM confirming the forwarder is working *before* waiting
on Sentinel ingestion — this makes debugging any "nothing showed up in
Sentinel" moment much faster live, and was genuinely how the two KQL bugs
above were found during this migration's own testing.
