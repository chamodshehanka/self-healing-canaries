# demo/ — presenter material (not part of the service)

- `pr1/` — the "feature PR" opened before the talk by `scripts/demo/prepare.sh`:
  migrate payment to inventory v2 + PSP v2. It carries two latent bugs:
  - **A** (shows in staging): inventory v2 omits `available` for multi-warehouse SKUs → 30% of checkouts fail.
  - **B** (shows only in prod): PSP v2 takes minor units; `toMinorUnits` assumes 2 decimals, so
    ¥1,500 becomes 150,000 and the PSP rejects it. Staging never sends JPY.
  Unit tests pass for both (that's the point).
- `fixes/` — known-good fixes, used by `scripts/demo/fallback-fix.sh` only if the live agent's
  patch doesn't build. The AI SRE is instructed not to read this directory.
