# Day 4 — Slide Changes (nginx+certbot+ModSecurity+rate-limit -> NPMplus+CrowdSec)

## What's different — summary

Day 4 goes from 4 steps to **3 steps**. Rate limiting is removed entirely (no
replacement — NPMplus has no per-host rate-limit control and none was added).
The remaining three steps (fake HTTPS -> real TLS -> WAF) keep the same
teaching beats but are driven through the NPMplus GUI/API instead of hand-
edited nginx config + compiled ModSecurity module.

## Step 1 — "port open != encrypted" (unchanged narrative, new mechanism)

**Remove**: the old flow generated a *self-signed*/absent cert scenario by
hand-editing `listen 443 ssl;` with no real cert.

**Replace with**:
1. In the NPMplus GUI (or via API — see `day4-handbook.md`), create a new
   **Proxy Host**: domain = the VM's Azure DNS label FQDN, forward to
   `127.0.0.1:8000`, **do not** toggle "Request a new SSL Certificate".
2. `curl -i http://<domain>/entries` — plaintext response, 200. Point out this
   is unencrypted even though it "looks fine."
3. **Screenshot to take**: the Proxy Host list showing the host with SSL
   column empty/off.

## Step 2 — Real TLS (certbot -> NPMplus GUI toggle)

**Remove**: all `certbot certonly --webroot` commands and the manual
`ssl_certificate`/`ssl_certificate_key` nginx directives.

**Replace with**: Proxy Host -> SSL tab -> "Request a new SSL Certificate" ->
select Let's Encrypt -> agree to ToS -> Save. Same HTTP-01 challenge under the
hood (NPMplus handles the ACME client and cert storage automatically).

- `curl -i https://<domain>/entries` -> `200`, valid cert.
- **Screenshot/diff to take**: `docker exec npmplus cat /data/nginx/proxy_host/<id>.conf`
  before and after — shows the `ssl_certificate` lines NPMplus injected
  automatically. Captured for real during this migration's testing; see
  `day4-handbook.md`.

## Step 3 — Rate limiting: REMOVE ENTIRELY

**Remove** the whole rate-limiting section/slide(s): the `limit_req_zone`
explanation, the `ab`/`for i in $(seq 1 30); do curl ...; done` demo, and the
429 status code discussion. NPMplus has no equivalent GUI/env control, and no
raw nginx custom-config workaround was added (deliberate choice — see
`day4-handbook.md` "Why no rate limiting" for the reasoning to give students
if asked). If the instructor wants to keep *a* mention of rate limiting as a
concept, do it as a single spoken aside, not a live demo: "a production
reverse proxy would normally rate-limit here; this particular tool doesn't
expose that as a simple toggle, which is itself a useful lesson about
evaluating security tools before adopting them."

## Step 4 (renumber to Step 3) — WAF: ModSecurity+CRS -> CrowdSec AppSec+CRS

**Remove**: the entire `nginx-module-modsecurity` compile-from-source section
(the `--with-compat` connector build, `libmodsecurity3`, `modsecurity-crs`
apt packages, `SecRuleEngine On` sed edit). This was the most fragile part of
the old stack and is gone completely.

**Replace with**:
1. Explain CrowdSec: an open-source, community-driven attack detection engine;
   its **AppSec** component does real-time WAF-style payload inspection
   (inline, not just log analysis). Collection `crowdsecurity/appsec-crs` is
   a genuine OWASP Core Rule Set port (confirmed via crowdsecurity/hub —
   tagged `modsecurity`, labeled "WAF: Non-Blocking OWASP Core Rule Set") so
   the "this is what real companies run" framing is preserved.
   **Important, confirmed by testing**: that "Non-Blocking" label is
   literally accurate — CrowdSec ships `crowdsecurity/crs` configured to run
   **out-of-band** by default, meaning it only scores/alerts *after* the
   request already reached your app; it never blocks in that mode. To get a
   real block, `setup-npmplus.sh` installs a custom appsec-config that runs
   the same CRS rules **in-band**. This is worth a slide of its own — "we
   deliberately reconfigured a security tool's documented default because the
   default doesn't do what its name implies" is a genuinely good lesson.
2. **Privacy/fine-print aside (new content, required)**: CrowdSec's default
   install shares detected attack signals with CrowdSec's central "Central
   API" / community blocklist by default (this is how the free tier's
   crowd-sourced blocklist works). Point students at `cscli console status`
   and the opt-out (`cscli console disable`, or setting `online_client: {}`
   empty in `/etc/crowdsec/local_api_credentials.yaml` before first
   enrollment) as a "read the fine print on security tools" teaching moment —
   this is exactly the kind of vendor trust question students should learn to
   ask.
3. Show the WAF OFF state first: `curl -i 'https://<domain>/entries?id=1+UNION+SELECT+*+FROM+users'`
   and `curl -i 'https://<domain>/entries?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E'`
   both return `200` (or whatever the app itself returns) — payload passes
   straight through.
4. Enable CrowdSec (exact commands in `day4-handbook.md`):
   ```
   docker exec crowdsec cscli bouncers add npmplus
   # paste the printed API key into /opt/npmplus/crowdsec/crowdsec.conf, set ENABLED=true
   cd /opt/npmplus && docker compose restart npmplus
   ```
5. Re-run the same two curl payloads -> both now return `403` from CrowdSec
   AppSec.
6. **Screenshot/diff to take**: `docker exec crowdsec cscli alerts list` showing
   the blocked-request alert with the offending payload, plus the per-host
   "Disable Crowdsec Appsec" checkbox in the NPMplus GUI (unchecked = WAF
   active for that host) — captured for real during this migration's testing.

**New required slide — "layered defenses interact"**: confirmed by testing —
once Day 2's oauth2-proxy Auth Request is wired on the same host (the normal
state by Day 4, since the course builds cumulatively), sending the SQLi/XSS
payloads *unauthenticated* no longer returns `403` from the WAF — it returns
`302` to the login page instead, because nginx evaluates `auth_request`
before CrowdSec's check on the same location. The request never reaches the
WAF-protected path. This is arguably *better* security (anonymous attackers
never reach the backend either way) but it changes the demo: show the WAF
block using a request that carries a **valid oauth2-proxy session cookie**
(log in once via browser first), which demonstrates CrowdSec protecting
authenticated users too — a stronger point than protecting anonymous ones.

## Timing

Net timing is similar to before once you remove the rate-limiting section:
the ModSecurity source-compile step it replaces was the single slowest part
of the old Day 4 (5-10 min of `make modules` compile time on a small VM);
CrowdSec's container start + collection install is faster (~1-2 min, already
done by `deploy.py`'s baseline). Expect the live demo itself (creating the
proxy host, TLS toggle, WAF wiring) to take about the same wall-clock time as
before, just spent on GUI clicks instead of watching a C compiler.
