# Day 1 — Slide Changes

## No changes needed — architecture unchanged

The NPMplus migration touches Day 2 (oauth2-proxy wiring) and Day 4 (nginx/TLS/WAF),
and adapts Day 5's log pipeline. Day 1's content — Entra ID SSH login via the
`AADSSHLoginForLinux` VM extension (`vm.tf`) replacing static SSH keys, plus the
NSG lockdown of port 22 to a trusted IP — is completely independent of how the
web front door (nginx vs. NPMplus) is built. Nothing in `vm.tf`'s
`azurerm_virtual_machine_extension.aad_ssh` resource or the AAD role-assignment
flow in `deploy.py` (`setup_aad_ssh`) changed.

## One incidental, optional talking point

Because Day 4 now stands up NPMplus's admin GUI on port 81 (see
`day4-slide-changes.md`), the instructor may optionally add a single callback
sentence near the end of Day 1's NSG section:

> "We're locking down port 22 today. On Day 4 you'll see this exact same
> instinct applied again — a management port (NPMplus's admin GUI on 81)
> that we deliberately do NOT open to the internet, using the same
> trusted-IP/SSH-tunnel thinking you just learned."

This is optional flavor text, not a required slide edit — do not add new
slides or restructure Day 1 for it.

## Timing

Unchanged. Day 1 timing is unaffected by the NPMplus migration.
