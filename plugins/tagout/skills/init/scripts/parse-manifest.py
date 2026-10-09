#!/usr/bin/env python3
"""parse-manifest.py — read a repo-setup manifest and emit one flat record per desired item.

Why this is a file and not a `python3 -c` inside repo-setup.sh. macOS still ships bash 3.2, and
its command-substitution scanner does not honour heredoc quoting: every quote in the body of a
heredoc opened inside `$( … )` is read as a shell quote, and an unpaired one runs the scanner to
end-of-file. That is #131, and `scripts/parse-sweep.sh` exists to catch it. A separate file has no
quoting relationship with its caller at all, so the hazard cannot arise — and the parser becomes
independently runnable, which is how tests/repo-setup asserts the shipped manifest declares the
three axes.

Output is tab-separated, one record per line, because tab is already the kit's internal field
separator (requirements.json says so, and forbids tabs in values for exactly this reason):

    L <TAB> name <TAB> color <TAB> description      a label
    T <TAB> filename                                an issue-form file
    S <TAB> key <TAB> value                         a repository setting
    K <TAB> glob                                    a label --prune must never delete
    O <TAB> name                                    a topic (#400)
    G <TAB> field <TAB> value                       a Pages field: source.branch, source.path,
                                                    build_type (#400)

Colours are normalised (leading '#' dropped, lower-cased) so that `d93f0b`, `#d93f0b` and
`#D93F0B` cannot read as three different desired states and produce a permanent ~EDIT that never
converges. Booleans are normalised to `true`/`false` for the same reason: PyYAML gives Python
`True`, `gh api` speaks JSON, and `str(True)` is `"True"`, which matches neither.

Exit codes:
  0  parsed
  2  unreadable or not valid YAML, or not a mapping (the caller turns this into its own exit 2)
"""
import re
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("PyYAML is required by repo-setup.sh — install it (pip install PyYAML)")


def die(message):
    # stderr is pinned for the same reason stdout is, and it matters precisely here: the messages
    # below interpolate manifest content (%r of a label name), so a name outside the console's
    # locale encoding would raise UnicodeEncodeError *inside the error path* — a traceback and
    # exit 1 in place of the diagnostic and exit 2 the caller's contract promises.
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.write("ERR: %s\n" % message)
    raise SystemExit(2)


# GitHub's documented cap on a label description is 100 CHARACTERS (not bytes — an em-dash is
# one, not three), and answers 422 Validation Failed for anything past it. That is knowable here,
# before any network round-trip, so refuse it locally with a message pointing at the manifest
# rather than let it reach `gh` and be misread as a permissions problem (#200).
LABEL_DESCRIPTION_LIMIT = 100

# GitHub's rules for the two surfaces #400 adds, checked here for the same reason the label cap
# is: a refusal that names the manifest line beats a 422 misread as a permissions problem.
# Topics: lowercase letters, digits and hyphens, 1-50 characters, at most 20 per repository.
# A repository description is capped at 350 characters by the PATCH endpoint.
TOPIC_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,49}$")
TOPICS_LIMIT = 20
REPO_DESCRIPTION_LIMIT = 350


def norm_scalar(value):
    """A YAML scalar as the string `gh` would compare against."""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value).strip()


def main(argv):
    if len(argv) != 2:
        die("usage: parse-manifest.py <manifest.yml>")
    path = argv[1]

    try:
        with open(path, encoding="utf-8") as handle:
            data = yaml.safe_load(handle)
    except OSError:
        die("cannot read the manifest '%s'" % path)
    except yaml.YAMLError as exc:
        die("the manifest '%s' is not valid YAML (%s)" % (path, exc.__class__.__name__))

    if data is None:
        data = {}
    if not isinstance(data, dict):
        die("the manifest '%s' must be a YAML mapping, got %s" % (path, type(data).__name__))

    out = []

    for entry in data.get("labels") or []:
        if not isinstance(entry, dict):
            die("every labels[] entry must be a mapping, got %s" % type(entry).__name__)
        name = norm_scalar(entry.get("name"))
        if not name:
            die("a labels[] entry has no name")
        if "\t" in name:
            die("label name %r contains a tab, which is this format's field separator" % name)
        color = norm_scalar(entry.get("color")).lstrip("#").lower()
        description = norm_scalar(entry.get("description"))
        if len(description) > LABEL_DESCRIPTION_LIMIT:
            die(
                "label %r description is %d characters, over GitHub's %d-character limit"
                % (name, len(description), LABEL_DESCRIPTION_LIMIT)
            )
        out.append("L\t%s\t%s\t%s" % (name, color, description))

    for entry in data.get("issueTemplates") or []:
        name = norm_scalar(entry)
        if not name:
            continue
        if "/" in name or name.startswith("."):
            die("issueTemplates[] takes a bare file name, got %r" % name)
        out.append("T\t%s" % name)

    for entry in data.get("pruneKeep") or []:
        pattern = norm_scalar(entry)
        if pattern:
            out.append("K\t%s" % pattern)

    settings = data.get("settings") or {}
    if not isinstance(settings, dict):
        die("settings must be a mapping, got %s" % type(settings).__name__)
    # Sorted so the emitted plan is stable run to run: an unstable order would make a converged
    # repo's report differ between runs, and a diff that changes on its own teaches nothing.
    for key in sorted(settings):
        value = norm_scalar(settings[key])
        if "\t" in value:
            die("setting %r contains a tab, which is this format's field separator" % key)
        # `description` is the one string setting with a documented cap (#400); the others the
        # PATCH accepts are booleans or short strings GitHub does not bound this way.
        if key == "description" and len(value) > REPO_DESCRIPTION_LIMIT:
            die(
                "settings.description is %d characters, over GitHub's %d-character limit"
                % (len(value), REPO_DESCRIPTION_LIMIT)
            )
        out.append("S\t%s\t%s" % (key, value))

    # Two more surfaces a public repository is judged by (#400). `O` and `G` rather than the
    # issue's `T`/`P`: `T` is already the issue-form record above, and a record letter that
    # reads two ways is the drift this format exists to prevent. The description and homepage
    # ride the `S` record — they are two more PATCH fields — with the cap checked just above.
    seen_topics = set()
    topics = data.get("topics") or []
    if not isinstance(topics, list):
        die("topics must be a list of names, got %s" % type(topics).__name__)
    if len(topics) > TOPICS_LIMIT:
        die("topics lists %d names, over GitHub's %d-topic limit" % (len(topics), TOPICS_LIMIT))
    for entry in topics:
        name = norm_scalar(entry)
        if not name:
            continue
        if not TOPIC_RE.match(name):
            die(
                "topic %r breaks GitHub's rule: lowercase letters, digits and hyphens, 1-50 "
                "characters, starting with a letter or digit" % name
            )
        if name in seen_topics:
            die("topic %r is listed twice" % name)
        seen_topics.add(name)
        out.append("O\t%s" % name)

    pages = data.get("pages")
    if pages is not None:
        if not isinstance(pages, dict):
            die("pages must be a mapping, got %s" % type(pages).__name__)
        source = pages.get("source")
        build_type = norm_scalar(pages.get("build_type"))
        if source is not None:
            if not isinstance(source, dict):
                die("pages.source must be a mapping with branch and path, got %s" % type(source).__name__)
            branch = norm_scalar(source.get("branch"))
            spath = norm_scalar(source.get("path")) or "/"
            if not branch:
                die("pages.source needs a branch")
            if spath not in ("/", "/docs"):
                die("pages.source.path must be / or /docs (GitHub accepts nothing else), got %r" % spath)
            out.append("G\tsource.branch\t%s" % branch)
            out.append("G\tsource.path\t%s" % spath)
        if build_type:
            if build_type not in ("legacy", "workflow"):
                die("pages.build_type must be legacy or workflow, got %r" % build_type)
            out.append("G\tbuild_type\t%s" % build_type)
        if source is None and not build_type:
            die("pages declares neither a source nor a build_type")

    if out:
        # Newlines are pinned to LF rather than left to `print`. On Windows, text-mode stdout
        # translates "\n" to "\r\n", and the caller splits these records on TAB — so the CR lands
        # inside the LAST FIELD of every record. Measured: a label description came back as
        # "Pull this first\r", which never equals what `gh` reports, so every label read as ~EDIT
        # and `apply` rewrote all of them on every run. Silent, idempotence-breaking, and invisible
        # on the Linux CI that would have to catch it (#174 is the same platform gap one layer up).
        # The ENCODING is pinned for the same reason and was the half this call originally left to
        # the locale. A Windows console is cp1252, so an em-dash in a description left as the
        # single byte 0x97 — invalid UTF-8 — `gh` sent that, and the label was created with a
        # description that can never equal what the manifest asks for. Measured 2026-08-20: ten
        # labels applied corrupted here, each reported ~EDIT by every later `plan`, so `apply`
        # rewrote all ten every run and converged on none (#196). This is the manifest's own text
        # reaching GitHub intact, not a display concern.
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
