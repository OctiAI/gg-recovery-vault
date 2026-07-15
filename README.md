# GoalsGraph recovery vault

This public repository intentionally contains only `age`-encrypted GoalsGraph PostgreSQL backups and their ciphertext manifests. It contains no plaintext database data, private encryption identities, production credentials, or interactive production access.

An hourly GitHub Actions collector downloads the latest encrypted candidate through a TLS-protected, Basic-Auth endpoint that can serve only the atomically generated ciphertext tar. The production VPS has no GitHub write credential. The collector verifies freshness and the ciphertext SHA-256 recorded in the manifest before making a fast-forward archive commit.

Retention in the visible archive is 35 days of hourly ciphertext plus 13 weekly ciphertext snapshots. A separate Denys-controlled runner holds the private `age` identity and performs restore drills; GitHub Actions never receives that identity.

An open GitHub issue named `GoalsGraph backup collector failure` is the independent alert receipt. The workflow opens it on collection failure and closes it after the next verified collection succeeds.

`scripts/restore-proof.ps1` performs the monthly isolated restore drill on the Denys-controlled Windows runner. A daily catch-up scheduler invokes it, but it performs a drill only when the last successful receipt is at least 28 days old. It streams decryption directly into a disposable PostgreSQL container, writes no plaintext dump to disk, records only non-sensitive success metadata locally, and opens `GoalsGraph restore proof failure` if it cannot complete.
