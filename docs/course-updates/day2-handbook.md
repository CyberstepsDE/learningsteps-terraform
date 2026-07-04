# Day 2 — Session Handbook (Entra ID JWT auth via oauth2-proxy, fronted by NPMplus)

Tested end-to-end against a live Azure deployment during this migration
(oauth2-proxy install, systemd unit, OIDC discovery against a real Entra ID
tenant, and NPMplus's Auth Request wiring — confirmed unauthenticated
requests correctly redirect to `/oauth2/sign_in`). The interactive browser
login round-trip itself was not automated (needs a human + real app secret,
which is also literally Day 2's teaching content, not something to script
away) — see the "What was and wasn't tested" note at the end.

## Ordered steps

1. Baseline is already up from `deploy.py` (NPMplus running, oauth2-proxy
   binary+unit installed but not started, no Proxy Host created yet).
2. SSH tunnel to the NPMplus admin GUI (port 81 is deliberately not opened in
   the NSG — see Day 1 callback):
   ```
   ssh -i .learningsteps_key -L 8081:localhost:81 azureuser@<vm-ip>
   ```
   Browse `https://localhost:8081`. Log in with
   `admin@learningsteps.local` / `LearningSteps123!` (fixed, not random —
   see "Why fixed admin creds" below).
3. Create the Proxy Host for the app (domain = VM's Azure DNS label FQDN,
   forward host `127.0.0.1`, port `8000`). Leave SSL off for now (Day 4 does
   TLS). **If scripting this via the API instead of the GUI, explicitly pass
   `"locations": []`** — see Day 4 handbook's troubleshooting for why leaving
   it unset breaks things later. The GUI's "Add Proxy Host" form does not
   have this problem.
4. `az ad app create` — Entra ID app registration (unchanged from before):
   ```
   APP_ID=$(az ad app create --display-name learningsteps-oauth2-proxy \
       --sign-in-audience AzureADMyOrg \
       --query appId -o tsv)
   az ad app update --id $APP_ID --identifier-uris api://$APP_ID
   SECRET=$(az ad app credential reset --id $APP_ID --query password -o tsv)
   TENANT_ID=$(az account show --query tenantId -o tsv)
   ```
   Note: `az ad app identifier-uri add` (used in earlier drafts of this
   handbook) is not a real subcommand — use `az ad app update --identifier-uris`
   instead (confirmed during testing).
5. On the VM, fill in `/etc/oauth2-proxy/oauth2-proxy.env`:
   ```
   OAUTH2_PROXY_CLIENT_ID=$APP_ID
   OAUTH2_PROXY_CLIENT_SECRET=$SECRET
   OAUTH2_PROXY_OIDC_ISSUER_URL=https://login.microsoftonline.com/$TENANT_ID/v2.0
   ```
   Edit `--redirect-url=https://<domain>/oauth2/callback` in
   `/etc/systemd/system/oauth2-proxy.service`, then:
   ```
   sudo systemctl daemon-reload
   sudo systemctl enable --now oauth2-proxy
   sudo systemctl status oauth2-proxy --no-pager
   ```
   Confirmed in testing: oauth2-proxy starts and successfully performs OIDC
   discovery against the real tenant issuer URL within a second.
6. In the NPMplus GUI, open the Proxy Host -> **Auth Request** tab -> select
   **oauth2proxy** -> Save.
7. Test:
   - `curl -i http://<domain>/` -> confirmed in testing: `302` redirect to
     `/oauth2/sign_in?rd=...` (unauthenticated).
   - `curl -i -H "Authorization: Bearer garbage" http://<domain>/` -> also
     `302` to sign-in (oauth2-proxy ignores the malformed bearer header and
     falls back to its normal cookie/redirect flow — it doesn't 401 outright
     the way a bespoke bearer-only API gateway might; call this out as a
     discussion point about what "reject a bad token" actually looks like
     for a browser-oriented auth proxy vs. an API-only one).
   - Browser: visit `https://<domain>/`, complete the Microsoft login, land
     on the app with a valid session cookie. (Not automated in this
     migration's testing — see below.)

## Why fixed (not random) admin credentials

NPMplus's default behavior is a randomly-generated admin password logged
once on first container start via `docker logs`. That's fine for a single
operator but impractical for a classroom where many people need to log into
the same GUI during a live demo, and — found during testing — the
`docker logs` output in the pinned image version didn't actually contain a
visible email/password line where the README implied it would (possibly
version-specific). `setup-npmplus.sh` sets `INITIAL_ADMIN_EMAIL` and
`INITIAL_ADMIN_PASSWORD` explicitly instead. Change these for anything beyond
a throwaway lab VM.

## Behind the scenes (config diff to show students)

Real before/after diff of `docker exec npmplus cat
/data/nginx/proxy_host/<id>.conf`'s `location /` block, captured during
testing:

Before:
```nginx
location / {
  proxy_set_header Host $host$is_request_port$request_port;
  proxy_pass http://upstream_1$request_uri;
}
```
After (Auth Request = oauth2proxy):
```nginx
location / {
  proxy_set_header Host $host$is_request_port$request_port;
  proxy_pass http://upstream_1$request_uri;

  auth_request /oauth2/auth;
  error_page 401 = @oauth2_signin;

  auth_request_set $user $upstream_http_x_auth_request_user;
  auth_request_set $email $upstream_http_x_auth_request_email;
  proxy_set_header X-User $user;
  proxy_set_header X-Email $email;
  auth_request_set $token $upstream_http_x_auth_request_access_token;
  proxy_set_header X-Access-Token $token;
  ...
}

location /oauth2 { proxy_pass http://auth_request_oauth2proxy_1; ... }
location /oauth2/auth { internal; proxy_pass http://auth_request_oauth2proxy_1; ... }
location @oauth2_signin { internal; return 302 /oauth2/sign_in?rd=...; }
```
This is the exact same `auth_request`/`error_page`/internal-location pattern
students used to hand-write — NPMplus generates it automatically from one
dropdown selection. Good moment to scroll through this file live and point
out each piece matches what they typed by hand before.

## Timing

- Steps 1-3: ~5 minutes (mostly SSH tunnel + GUI clicking).
- Step 4 (`az ad app create` + role/secret plumbing): ~5 minutes, same as
  before.
- Steps 5-7: ~5-10 minutes including systemd restart and a first login
  round-trip.

## What was and wasn't tested in this migration

Tested for real: oauth2-proxy install/systemd unit, OIDC discovery against
the real `cybersteps.de` tenant, NPMplus's Auth Request dropdown correctly
generating the `auth_request` block, and the unauthenticated-redirect
behavior (`302` to sign-in for both no-token and garbage-token requests).

Not automated (by design, not by oversight): the actual interactive
browser-based Microsoft login round trip. This requires a human clicking
through a real login form, which is (a) not something a CLI-driven test can
do meaningfully, and (b) literally the point of Day 2 as a live demo — a
scripted pass-through would prove nothing about the concept being taught. A
temporary Azure AD app registration was created and deleted during testing to
validate the pieces above; its client secret was deliberately never printed
or persisted to disk (the agent tooling used for this migration blocks that
class of action) — a placeholder secret was used for the config-wiring test
instead.

## Troubleshooting (all real issues hit during this migration's testing)

- **`az ad app identifier-uri add` doesn't exist**: use
  `az ad app update --id $APP_ID --identifier-uris api://$APP_ID` instead.
- **Auth cookie / login session issues after restarting NPMplus**: NPMplus's
  admin session cookie can return `403 Permission Denied` (JSON) shortly
  after an `npmplus` container restart even though the JWT signing key
  persists to disk — re-run the `POST /api/tokens` login call to get a fresh
  cookie rather than assuming the container needs `INITIAL_ADMIN_*` reset.
- **`docker: 'docker logs' requires 1 argument` printed during
  `setup-npmplus.sh`**: harmless — appears to be internal container startup
  noise (possibly from NPMplus's own log-rotation/health self-check trying to
  introspect via a docker CLI without the socket mounted). Did not affect
  functionality in any test run; safe to ignore.
- See the Day 4 handbook for the `locations: null` API bug and the
  auth-request-vs-WAF ordering issue, both of which surface when Day 2's
  Auth Request and Day 4's CrowdSec are both wired on the same host (the
  normal cumulative state by the time Day 4 is taught).
