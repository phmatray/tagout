---
id: 19
title: Local tracker backend
status: rejected
date: 2026-11-03
tags:
- out-of-scope
parent: Architectural Decision Records
nav_order: 19
---

# Local tracker backend

## Context and Problem Statement

The tracker contract (ADR-0015) routes each lifecycle skill's tracker call to one backend per
hosted service: GitHub, GitLab and Azure DevOps. #742 asked for a fourth backend with no service
behind it: issues as Markdown files committed in the repository under `.tagout/issues/`, for
air-gapped networks, repositories that must not leave the machine yet, sandboxes and CI jobs. Its
author stated the need was anticipated, with no measurement behind it.

## Considered Options

- A `local` backend storing issues as Markdown with YAML front matter in the repository, covering
  `create-issue`'s verbs first.
- A Gitea or Forgejo backend run locally.
- SQLite under `.git/`, or git notes on a dedicated branch.
- Decline: the tracker contract serves hosted trackers, and no user is blocked without a hosted one.

## Decision Outcome

Not pursued by decision (2026-11-03): the tracker contract's scope is the hosted trackers GitHub,
GitLab and Azure DevOps (#503 excludes every other host), and a repository-file store would add a
committed issue format users come to depend on, to serve a need no user has reported.

## Consequences

A repository with no hosted tracker keeps using the migration pipeline and `debug-issue`, and the
lifecycle skills refuse it at Step 1 through `tracker.capable`, which stays the honest answer. No
`.tagout/issues/` format exists to keep compatible.

The one condition that reopens this: a named user or team blocked because a hosted tracker is
unavailable to them, reported on an issue, once `implement-issue` also runs on the contract so that
a local backend could carry work past planning. Reopening is a fresh ADR plus `set_status
deprecated` here, never an edit in place.

## Prior requests

- #742 — A "local" tracker backend, issues as Markdown files in the repository, offline tracker,
  air-gapped, no hosted service, file-based backlog (2026-11-01).
