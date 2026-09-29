# Shared Test-Seams Doctrine: where a test observes behaviour through

Ported from mattpocock/skills `engineering/tdd/SKILL.md` §Seams and §Anti-patterns, `tests.md` and
`mocking.md` (MIT). This file is the one home for the doctrine — a Spec's `### Testing decisions`
heading (`skills/create-issue/SKILL.md` Step 5) links here instead of restating it, and so does the
plan preamble's `**Seams under test:**` line (Step 6).

## What a seam is

A seam is the **public boundary** you observe behaviour through: a script's exit code and stdout, a
stubbed `gh` or `dotnet` on `PATH`, a rendered file, an issue's checkbox state read back over the API.
Tests live at seams. They never reach past one to assert on an internal — a helper function's return
value, a variable's contents mid-script, the order two private calls happened in. The internal is
free to change shape on the next refactor; the seam is the contract a caller (a human, CI, another
skill) actually depends on, and it is the only thing a test may hold constant.

`tests/survey/test.sh` is the worked example already in this tree: its `gh` stub applies the same
`--jq EXPRESSION` argument the real `gh issue list` does, rather than the stub always `cat`-ing a
fixture regardless of the flags it was called with. The test would still pass either way — until the
script's own `--jq` usage changed shape, at which point a stub that ignores flags keeps passing while
observing nothing real. Applying the flag is what keeps the test at the seam (`gh`'s own CLI contract)
instead of drifting to "however the stub happens to be built."

## Choose seams before tests

Pick the seam **before** writing the first test, not while writing it — a seam chosen mid-test is
usually just wherever the code happens to be:

1. **Existing seams first.** `tests/skills/test.sh` and `tests/survey/test.sh` already exercise a
   checker's exit code + message and a stubbed `gh` respectively; a new test that fits one of those
   boundaries should use it rather than inventing another.
2. **New ones at the highest point possible.** When no existing seam covers the behaviour, place the
   new one as close to the real caller's boundary as the test can reach — a script's own exit code and
   output, not a sourced function three layers in.
3. **The ideal number is one.** A test that has to coordinate two or three seams to make an assertion
   is usually testing plumbing, not behaviour — that is the horizontal-slicing anti-pattern below,
   arriving early.

## Mock at boundaries only

Stub or fake **external** dependencies only: another program on `PATH` (`gh`, `dotnet`, `jq`), the
network, the clock, the filesystem outside the tree under test. In this kit that means a stubbed `gh`
or `dotnet` shim placed ahead of the real one on `PATH` (`tests/survey/test.sh`'s `$WORK/bin` prefix
is the pattern), never a sourced shell function or a Python module the code under test owns. Mocking
your own module hides the real integration — the seam moves from "does this script actually call `gh`
correctly" to "does this script call the function I renamed to look like `gh`", which is a different
and much weaker question.

## Anti-patterns

**Implementation-coupled** — the test breaks when a refactor changes *how* the code works even though
*what it does* is unchanged: asserting the order two independent steps ran in, reaching into a
private variable instead of the seam's own output, or verifying through a side channel (a log line,
a debug file) that only exists as an implementation detail. Refactor-proof means asserting the seam's
contract, not its current shape.

**Tautological** — the expected value is recomputed the *same way the code under test computes it*,
so the test can never disagree with a bug: a checker that fails when `X` is out of sync would pass a
test that greps the script's own variable definition of `X` back out of itself, because both sides
read the identical spelling. The fix is an expected value from an **independent** source — a literal
written by hand, a fixture checked into the test, the documented contract — not a second read of the
same line the implementation already trusts.

The hand-written literal has a trap of its own: a test that pins a constant to its own value
(`MAX_LENGTH = 280`, then `assert MAX_LENGTH == 280`) only restates the declaration. It fails on a
deliberate change and never on a bug. Assert the behaviour the constant governs instead: an input of
280 is accepted and 281 is refused.

**Horizontal slicing** — writing every test first, across every task, then implementing all the code
afterward. It defers the seam question until the whole surface is already speculative, and a plan
written that way produces a wall of red tests with no single one telling you which piece to build
next. Work one tracer bullet at a time instead: one task, its seam, its test, its code, green, commit
— then the next.
