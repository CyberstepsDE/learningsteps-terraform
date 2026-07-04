# Day 3 — Session Handbook (PostgreSQL Private Link)

Current content mostly applies unchanged. This handbook only calls out
timing effects from the new `deploy.py` baseline and confirms nothing in the
DB migration procedure was touched.

## Ordered steps (unchanged from before)

1. `pg_dump` the existing database from the VM (jump host) before recreating
   the server with VNet integration.
2. Update `postgresql.tf` (delegated subnet + private DNS zone — already in
   place on this branch, inherited unchanged from the pre-migration checkpoint
   commit `1001efd`).
3. `terraform apply` — this **destroys and recreates**
   `azurerm_postgresql_flexible_server.main` (public access -> private).
   Confirmed still true on this branch: no changes to `postgresql.tf` were
   made during the NPMplus migration.
4. Restore from the VM via `psql` over the private link.

## Timing note

Because `deploy.py` now also stands up NPMplus + CrowdSec (Docker image pulls)
as part of the same run, a full from-scratch `deploy.py` run is ~9-12 minutes
before you even get to the Day 3 DB recreation exercise (which is typically
done as a `terraform apply -target=...` or full re-apply after editing
`postgresql.tf` by hand, separately from the initial `deploy.py` run). If Day
3 is taught as a modification of an already-running Day 1/2 environment (the
normal flow), this has no practical effect — the DB recreation apply itself
is unaffected and takes the same ~5-8 minutes it always did (PostgreSQL
Flexible Server recreation dominates the wait, not anything Docker-related).

## Troubleshooting

No new issues encountered — this path was not touched by the migration and
the existing Day 3 troubleshooting notes (if any) still apply as-is.
