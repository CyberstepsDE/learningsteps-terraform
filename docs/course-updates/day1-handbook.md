# Day 1 — Session Handbook (Entra ID SSH + NSG lockdown)

Current content mostly applies unchanged. This handbook only calls out what's
different because of the NPMplus migration (deploy.py timing) and reflects the
real deploy.py run captured during this migration's testing.

## Ordered steps

1. `python3 deploy.py --password <pw> --prefix <name> --location westeurope`
   - Terraform init + apply: provisions VNet, NSG, VM (with `AADSSHLoginForLinux`
     extension), PostgreSQL Flexible Server, Sentinel/Log Analytics workspace.
   - **New timing note**: deploy.py now also runs the Day 2/4 baseline setup
     (Docker + NPMplus + CrowdSec + oauth2-proxy install + log forwarder) as
     part of the same script run, immediately after the API health check.
     Total end-to-end `deploy.py` runtime observed during testing: **~9-12
     minutes** (cloud-init/API ~3-5 min, NPMplus+CrowdSec image pull ~3-5 min).
     This is a good stopping point to start Day 1's actual lecture content
     while Terraform finishes — the AAD SSH role assignment and NSG resources
     are usually done within the first 60-90 seconds of apply.
2. Confirm the role assignment: `az role assignment list --assignee <you> --role "Virtual Machine Administrator Login"`.
3. `az ssh vm --resource-group <rg> --name <vm-name>` — demonstrate AAD login,
   no key file.
4. Live-edit `network.tf`'s `allow-ssh` rule to restrict `source_address_prefix`
   from `"*"` to the classroom's trusted IP (`curl -s ifconfig.me`), then
   `terraform apply` again to show the NSG rule take effect immediately (test
   that a non-trusted IP now gets connection-refused/timeout on 22, or discuss
   conceptually if only one network is available in the room).

## Troubleshooting (from real testing on this branch)

- **`az ssh` extension missing**: `deploy.py`'s `check_prerequisites()` now
  auto-installs it (`az extension add --name ssh --yes`) — no manual step
  needed, but if running commands outside `deploy.py`, install it first.
- **Role assignment fails with "AuthorizationFailed"**: the signed-in user
  needs Owner or User Access Administrator on the subscription to grant
  themselves "Virtual Machine Administrator Login". `deploy.py` degrades
  gracefully (prints a `warn()` with the exact manual command) instead of
  failing the whole run — confirmed this path still works after the
  NPMplus changes (it's untouched code).
