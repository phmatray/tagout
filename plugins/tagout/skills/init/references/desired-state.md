# The desired state

`templates/repo-setup.yml` in the kit is the shipped default. A consumer repo overrides it by
committing its own `.github/repo-setup.yml`, which `repo-setup.sh` prefers — so a consumer's
taxonomy survives a kit upgrade. `--manifest <path>` overrides both.

Six rules govern what `apply` will and will not do, and they are worth relaying to the operator
before the first run against a repo that already has labels:

- **Additive.** A live label the manifest does not declare is reported `!EXTRA` and **kept**. Only
  `--prune` deletes anything. A repo already running `P1`/`P2` must not have its taxonomy renamed
  out from under it.
- **`pruneKeep` outranks `--prune`.** Labels a *tool* owns look undeclared because no human
  declares them, and deleting them breaks the automation that reads them. The manifest's
  `pruneKeep` globs — seeded with release-please's `autorelease: *` and Renovate's `dependencies` —
  are reported `!KEEP` and never deleted. Add the repo's own bot labels there before running
  `--prune` on it.
- **Never clobber.** An issue form that already exists is reported `!SKIP`. A tuned form outranks
  the kit's default.
- **A name in angle brackets is a placeholder** — never created, and reported `!TODO` **and counted
  as drift** on every run (`plan` exits 1), so an unfilled axis stays visible instead of looking
  converged (#198). The `area:` axis ships this way because it names the consumer's code, not the
  kit's: fill it in before `auto-dev` runs a fleet — `apply` will not resolve this one for you.
- **Topics are additive, like labels** — and only when the manifest declares `topics:` at all. A
  live topic the manifest does not name is reported `!EXTRA` and kept; `--prune` drops it. A
  manifest silent on topics never reads or writes them, `--prune` included.
- **The Pages site is created or updated, never disabled.** A 404 on the read means *no site
  yet* and plans a `+ADD`; a 403 is a refusal by name, like every other surface. Disabling a
  site is not a converge, so `init` never issues that `DELETE`.
