# Day 4 — Session Handbook (TLS + WAF via NPMplus + CrowdSec)

3 steps now (rate limiting removed): unencrypted -> TLS -> WAF. All three were
tested for real end-to-end against a live Azure deployment during this
migration (`rg-npmplustest`) using the NPMplus REST API in place of clicking
through the GUI (both are documented — see "GUI vs API" below).

## Ordered steps

### 1. Unencrypted baseline

Create the Proxy Host (GUI: Hosts -> Proxy Hosts -> Add Proxy Host; API
equivalent below). **Important**: explicitly include `"locations": []` in the
create/update payload if driving this via API — leaving it unset stores
`null`, which crashes NPMplus's config renderer later when you add an Auth
Request provider (see Troubleshooting).

```bash
curl -sk -X POST https://localhost:81/api/nginx/proxy-hosts \
  -b npm.cookies -H "Content-Type: application/json" \
  -d '{"domain_names":["<domain>"],"forward_scheme":"http","forward_host":"127.0.0.1","forward_port":8000,"locations":[]}'

curl -i http://<domain>/entries
```
Expect `200` plaintext, confirmed working in testing.

### 2. Real TLS via Let's Encrypt

GUI: Proxy Host -> SSL tab -> "Request a new SSL Certificate" -> Let's
Encrypt -> agree to ToS -> Save. API equivalent (also tested, completed in
~30s in our test run):
```bash
curl -sk -X POST https://localhost:81/api/nginx/certificates \
  -b npm.cookies -H "Content-Type: application/json" \
  -d '{"provider":"letsencrypt","domain_names":["<domain>"],"meta":{"dns_challenge":false}}'
# then attach it and force SSL:
curl -sk -X PUT https://localhost:81/api/nginx/proxy-hosts/<id> \
  -b npm.cookies -H "Content-Type: application/json" \
  -d '{"certificate_id":<cert_id>,"ssl_forced":true}'
```
```
curl -i https://<domain>/entries
```
Confirmed `200` over TLS with a real Let's Encrypt cert; plain HTTP now `301`s
to HTTPS.

**Behind the scenes** — real before/after diff of `docker exec npmplus cat
/data/nginx/proxy_host/<id>.conf`, captured during testing:

Before (SSL off):
```nginx
server {
  server_name npmplustest.westeurope.cloudapp.azure.com;
  listen 0.0.0.0:80;
  listen [::]:80;
  location / {
    proxy_pass http://upstream_1$request_uri;
  }
}
```
After (SSL forced):
```nginx
server {
  server_name npmplustest.westeurope.cloudapp.azure.com;
  listen 0.0.0.0:80;
  listen 0.0.0.0:443 ssl;
  listen 0.0.0.0:443 quic;
  ssl_certificate /data/tls/certbot/live/npm-1/fullchain.pem;
  ssl_certificate_key /data/tls/certbot/live/npm-1/privkey.pem;
  if ($scheme = "http") { return 301 https://$host$is_request_port$request_port$request_uri; }
  location / {
    proxy_pass http://upstream_1$request_uri;
  }
}
```
NPMplus auto-injects the cert paths, the HTTP->HTTPS redirect, and even HTTP/3
(QUIC) listeners — none of this is hand-typed.

### 3. WAF: CrowdSec AppSec + CRS

**Critical finding, confirmed by testing — read before teaching this live**:
CrowdSec's `crowdsecurity/crs` ruleset ships from upstream configured as
**out-of-band** (see `/etc/crowdsec/appsec-configs/crs.yaml` inside the
crowdsec container: `outofband_rules: [crowdsecurity/crs]`). Out-of-band means
it only scores and alerts *after* the request already reached your app — it
**never blocks the current request**. This matches CrowdSec's own hub label
for the collection, "WAF: Non-Blocking OWASP Core Rule Set" — that label is
literally true, not just a default. `setup-npmplus.sh` writes a custom
appsec-config, `/opt/crowdsec/conf/appsec-configs/crs-inband.yaml`, that loads
the same CRS rule content **in-band** so it actually blocks:
```yaml
name: crowdsecurity/crs-inband
default_remediation: ban
inband_rules:
 - crowdsecurity/crs
```
This is already wired into the baseline `deploy.py` sets up (via `acquis.d/npmplus.yaml`
referencing `crowdsecurity/crs-inband` instead of `crowdsecurity/crs`). Tell
students this explicitly — it's a great "read past the marketing label" moment.

Show OFF state first (confirmed: both return 200, no block):
```
curl -i "https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users"
curl -i "https://<domain>/entries?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
```

Enable CrowdSec:
```
docker exec crowdsec cscli bouncers add npmplus
# copy the printed API key — shown ONCE, save it now
sudo nano /opt/npmplus/crowdsec/crowdsec.conf
#   ENABLED=true
#   API_URL=http://127.0.0.1:8080
#   APPSEC_URL=http://127.0.0.1:7422
#   API_KEY=<paste key>
cd /opt/npmplus && docker compose restart npmplus
```
Confirmed both payloads now return `403` (SQLi and XSS both matched CRS rules
with `anomaly score block` in `cscli alerts list`).

Show the block: `docker exec crowdsec cscli alerts list` — real captured output:
```
| ID | value           | reason                                        | kind |
| 5  | Ip:77.125.97.10 | anomaly score block: xss: 40, anomaly: 40     | waf  |
| 4  | Ip:77.125.97.10 | anomaly score block: sql_injection: 40        | waf  |
```

**Privacy aside**: CrowdSec's default install shares detected attack signals
with its central "Console"/community blocklist. `cscli console status` shows
enrollment state; `cscli console disable` opts out. Mention this out loud as
a "read the fine print on security tools" moment regardless of whether the
class opts out for the demo.

## GUI vs API for the live demo

**Recommendation: do the demo in the GUI.** The API (used for this migration's
scripted testing) requires a cookie-based session token (`POST /api/tokens`,
then send the `__Host-Http-token` cookie on every call) and exact JSON field
names that aren't obvious without reading `/api/schema` — fine for automation,
fiddly to type live in front of a class. The GUI dropdowns/toggles map 1:1 to
the same underlying fields and are much better for a room of students to
follow along with. Use the API only for the "before/after config diff"
reveal moments, which work identically either way.

## Why no rate limiting

NPMplus has no per-host rate-limit GUI control or env var (verified against
the current `compose.yaml` and README — confirmed absent, not just
undocumented). Adding a raw custom nginx snippet workaround was explicitly
ruled out, to avoid re-introducing hand-edited nginx config that NPMplus's
own config generator doesn't know about and could silently overwrite on the
next GUI/API save. If a class wants to keep teaching rate limiting as a
concept, do it as a discussion, not a live demo (see `day4-slide-changes.md`).

## Timing

- Step 1: ~2 min.
- Step 2: ~1 min (ACME issuance took ~30s in testing, well under the old
  certbot flow's typical time).
- Step 3: ~10 min (bouncer registration + config edit + restart + re-test).

## Troubleshooting (all real errors hit during this migration's testing)

- **`data must NOT have additional properties` on Proxy Host create**: the
  NPMplus API's JSON schema is strict — send only `domain_names`,
  `forward_scheme`, `forward_host`, `forward_port` (+ `locations: []`) for a
  minimal create; extra fields from older NPM API examples (e.g.
  `access_list_id`, `caching_enabled` set explicitly) may be rejected
  depending on version. Check `GET /api/schema` (OpenAPI 3.1) if unsure.
- **Login returns `{"expires": "..."}` with no visible token**: the auth
  token is delivered as an **HttpOnly cookie** (`__Host-Http-token`), not in
  the JSON body. Use `curl -c cookies.txt ... /api/tokens` then `-b
  cookies.txt` on subsequent calls (or a browser, which handles this
  automatically).
- **`403 Forbidden` (plain HTML, not JSON) on admin API calls once CrowdSec
  is enabled**: CrowdSec's AppSec bouncer protects the **entire nginx
  instance once enabled**, including NPMplus's own admin GUI/API on port 81 —
  not just the proxy-host locations you intended to protect. CRS's default
  paranoia level has a well-known false-positive rate against legitimate
  JSON PUT/POST bodies, and it intermittently blocked our own admin API calls
  during testing. Workaround used during testing: temporarily set
  `ENABLED=false` in `/opt/npmplus/crowdsec/crowdsec.conf`, make the admin
  change, then re-enable. For a real deployment, consider adding an
  allowlist for the admin IP/localhost in CrowdSec instead.
- **Selecting an Auth Request provider produces `1.conf.err` instead of
  `1.conf`** (proxy host silently stops working, `docker exec npmplus ls
  /data/nginx/proxy_host/` shows the `.err` file): this happens when the
  Proxy Host's `locations` field is `null` instead of `[]` — NPMplus's config
  renderer does `[...host.locations]` internally, which throws on `null`.
  Fix: `PUT` the host with `{"locations": []}` explicitly. This is a real
  NPMplus bug at the version tested (`2026-06-25-r1`); a fresh Proxy Host
  created without ever specifying `locations` defaults to `null` unless you
  explicitly pass `"locations": []` on creation (the GUI's "Add Proxy Host"
  form does not have this problem — it always saves `[]`; this only bites
  API-driven automation).
- **`AUTH_REQUEST_OAUTH2PROXY_UPSTREAM` env var present but the generated
  nginx `upstream` block has an empty `server ... resolve;` line** (nginx
  config fails validation): same root cause as above (`locations: null`
  crashing the renderer mid-way through building the auth-provider upstream
  block) — fixing `locations` to `[]` also fixes this.
- **Container marked `(unhealthy)` after an env var change**: if
  `AUTH_REQUEST_OAUTH2PROXY_UPSTREAM` is set without a scheme (e.g.
  `127.0.0.1:4180` instead of `http://127.0.0.1:4180`), NPMplus refuses to
  start cleanly and logs `"...needs to contain the scheme..."`. Always
  include `http://` or `https://`.
- **CrowdSec bouncer config needs more than the docs say**: docs.crowdsec.net's
  NPMplus quickstart implies `ENABLED` + `API_KEY` alone are enough in
  `/opt/npmplus/crowdsec/crowdsec.conf`. In testing, without explicit
  `API_URL=http://127.0.0.1:8080` and `APPSEC_URL=http://127.0.0.1:7422`,
  NPMplus logs `"Neither API_URL or APPSEC_URL are defined, remediation
  component will not do anything"` and nothing is actually blocked. Always
  set all four fields.
- **IMPORTANT — WAF test payloads silently stop returning 403 once Day 2's
  oauth2-proxy Auth Request is wired on the same host**: nginx evaluates the
  `auth_request` directive's access-phase handler before CrowdSec's
  `access_by_lua` handler on the same location. An unauthenticated attacker
  sending a SQLi/XSS payload gets redirected to `/oauth2/sign_in` (302)
  *before* the request ever reaches the WAF check — confirmed by testing (6
  attack requests, all 302, zero new CrowdSec alerts). This is actually
  *correct* security behavior (unauthenticated traffic never reaches the
  protected backend path either way) but it breaks the "send a raw curl
  payload, watch it get blocked" demo once both days' protections are layered
  on the same host, which is the normal cumulative course structure by Day 4.
  **Recommended fix for the live demo**: log in once via a real browser
  session (or curl with a valid `_oauth2_proxy` session cookie) and send the
  SQLi/XSS payloads *with that cookie attached* — this demonstrates the more
  realistic and arguably more important property that CrowdSec protects
  **authenticated** users too, not just anonymous ones. Call this out
  explicitly as a slide talking point (see `day4-slide-changes.md`).
