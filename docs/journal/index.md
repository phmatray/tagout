---
title: Journal
nav_order: 9
nav_group: internals
has_children: true
---

# Journal

One article per published release, newest on top, the earlier ones stapled beneath it. `CHANGELOG.md`
answers *what changed if I update?*; this answers *why did we do that, and what did we learn?* Read it
from the bottom up and the kit's evolution reads as a story rather than a diff.

Two prose rules, enforced by `tests/skills/test.sh` rather than by review: every article is in
English, and no article contains an em dash. Use commas, colons, parentheses or separate sentences
instead. French quoted inside guillemets does not count against the first rule, so an article can
still quote what a skill actually says.

## Adding the next article

When a release lands:

1. Copy the newest article to `docs/journal/v<the new version>.md`.
2. Set `nav_order` to the previous article's plus one. Never renumber an existing article.
3. Rewrite the body from `gh release view v<the new version>` and
   `git log v<previous>..v<the new version> --oneline`, in the voice of whoever shipped it: what the
   release was answering, what was decided, what got cut, what bit us.
4. Run `./tests/skills/test.sh`.

The guard checks both what is here and what is missing: it holds every article to the two prose
rules and to a unique `nav_order`, and it also requires every published release except the newest to
have a `docs/journal/<tag>.md` article, so the journal cannot silently go stale. A checkout with no
`v*` tags at all is refused rather than treated as passing, since silence there would hide every
missing article instead of catching it.

The exemption is exactly one release wide, always: the newest tag by creation time. On a day with
several releases (this repository has tagged six in one afternoon) the gate goes red for every open
pull request the moment a second release is tagged, because the release that was newest a minute
ago is now an older tag with no article. That is the gate working, not a bug. The recovery is to
write the missing articles, oldest tag first; the refusal names every missing tag, so nothing has to
be worked out by hand.
