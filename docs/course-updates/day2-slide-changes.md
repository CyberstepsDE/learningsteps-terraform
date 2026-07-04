# Day 2 — Slide Changes (oauth2-proxy wiring moves to NPMplus)

## What's different

Previously (manual, not codified in this repo): nginx sat in front of
oauth2-proxy on :80, with a hand-written `auth_request /oauth2/auth;` block in
nginx.conf, and oauth2-proxy itself listened on :4180 upstream of FastAPI
:8000. Slides walked through editing `nginx.conf` by hand to add the
`auth_request` and `error_page 401 = /oauth2/sign_in` directives.

Now: NPMplus replaces hand-edited nginx entirely. NPMplus ships a built-in
"Auth Request provider" dropdown specifically for oauth2-proxy — no nginx
config is hand-edited at all. The Entra ID app-registration flow (the actual
teaching content of Day 2) is **completely unchanged**.

## Concrete slide edits

1. **Remove** any slide/section showing raw `nginx.conf` `auth_request`
   directives (e.g. `auth_request /oauth2/auth;`, `error_page 401 =
   /oauth2/sign_in;`, the internal `location = /oauth2/auth` block). This
   content no longer exists in the stack.

2. **Keep unchanged**: the `az ad app create` walkthrough —
   ```
   az ad app create --display-name learningsteps-oauth2-proxy \
       --sign-in-audience AzureADMyOrg \
       --identifier-uris api://$APP_ID
   az ad app credential reset --id $APP_ID
   ```
   and the discussion of API keys vs. identity tokens. This is still the
   day's core lesson.

3. **Replace** the "install/configure oauth2-proxy" section with:
   - `scripts/setup-oauth2-proxy.sh` has already run as part of `deploy.py`
     (baseline install: binary at `/usr/local/bin/oauth2-proxy`, systemd unit
     at `/etc/systemd/system/oauth2-proxy.service`, NOT started).
   - Live demo: edit `/etc/oauth2-proxy/oauth2-proxy.env` on the VM, filling
     in `OAUTH2_PROXY_CLIENT_ID`, `OAUTH2_PROXY_CLIENT_SECRET`,
     `OAUTH2_PROXY_OIDC_ISSUER_URL=https://login.microsoftonline.com/<TENANT_ID>/v2.0`.
     A cookie secret is already pre-generated.
   - Edit the `--redirect-url` in `/etc/systemd/system/oauth2-proxy.service`
     to match the real domain (`https://<domain>/oauth2/callback`), then:
     ```
     sudo systemctl daemon-reload
     sudo systemctl enable --now oauth2-proxy
     ```

4. **Add new slide**: "Wiring NPMplus to oauth2-proxy" —
   - In `compose.yaml` (already baked in by `setup-npmplus.sh`):
     `AUTH_REQUEST_OAUTH2PROXY_UPSTREAM=http://127.0.0.1:4180`
   - In the NPMplus GUI: open the app's Proxy Host -> **Auth Request** tab ->
     select **oauth2proxy** from the dropdown -> Save.
   - **Screenshot to take**: the Auth Request dropdown showing "oauth2proxy"
     selected, and a before/after diff of
     `/data/nginx/proxy_host/<id>.conf` inside the NPMplus container showing
     the `auth_request` block NPMplus generated automatically (captured for
     real during this migration's testing — see `day2-handbook.md` "Behind
     the scenes" section for the actual diff).

5. **Test sequence slide** (update commands, same narrative as before):
   - `curl -i https://<domain>/` -> expect `401`/redirect to Microsoft login
     (no bearer token).
   - `curl -i -H "Authorization: Bearer garbage" https://<domain>/` -> expect
     `401`.
   - Browser flow with a real Entra ID login -> `200`, app content loads.

## Timing

No material change — the Entra app registration and OIDC round-trip take the
same ~10-15 minutes of live demo time as before. The nginx-config-editing
portion (previously ~5-10 min of live typing) is replaced by a ~2-minute GUI
dropdown selection, which is a net time savings the instructor can spend on
deeper OIDC/JWT discussion instead.
