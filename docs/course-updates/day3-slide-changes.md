# Day 3 — Slide Changes

## No changes needed — architecture unchanged

Day 3 moves PostgreSQL Flexible Server onto VNet integration / Private Link:
a delegated subnet (`azurerm_subnet.db` in `network.tf`), a private DNS zone
(`privatelink.postgres.database.azure.com`), and the pg_dump-backup /
terraform-recreate / restore-via-VM-jump-host workflow. None of this depends
on what runs in front of the FastAPI app on the VM (nginx vs. NPMplus,
ModSecurity vs. CrowdSec). `postgresql.tf`, the `azurerm_subnet.db` delegation,
and the private DNS zone resources in `network.tf` are untouched by the
NPMplus migration.

The only thing that changed anywhere near Day 3 is that `provider.tf` and
`postgresql.tf` were carried into this branch's checkpoint commit exactly as
they were before the migration work started — no further edits were made to
either file for this migration.

## Timing

Unchanged. The VM-as-jump-host restore procedure works identically regardless
of what's listening on ports 80/443/8000 on that VM.
