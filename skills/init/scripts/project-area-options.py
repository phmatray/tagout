#!/usr/bin/env python3
# project-area-options.py — rewrite a copied issue form's Area dropdown from the manifest (#198).
#
# `apply` copies templates/issue-forms/*.yml verbatim, so the dropdown it ships is whatever the
# KIT declared — its shipped default is the lone "area: <your-area>" placeholder. A consumer who
# fills in their own `area:` labels and runs `apply` therefore got a form that forces a label
# `apply` is designed never to create (#198). This is the writer half of that fix: given a form
# already copied onto disk and the manifest's own area labels, rewrite just the `options:` list
# under the field whose `id` is `area`, in place.
#
# A full YAML load-and-dump would reflow the whole document and destroy the shipped forms'
# comments and block scalars (the `description: >-` folded blocks), so this is a LINE-RANGE
# replacement: locate the block by parsing, but edit by lines. Same reasoning parse-manifest.py
# gives for never round-tripping a manifest it only needs to read.
#
# Usage: project-area-options.py <form.yml> <area-label>...
#
# Exit codes:
#   0  the options: list was rewritten
#   2  bad usage, or the file could not be read / is not valid YAML
#   3  no dropdown field with id: area was found, or its options: block is not the plain
#      quoted-scalar list this script knows how to rewrite — the CALLER reports this and
#      continues; it is never a failed `apply` (a copied-but-unprojected form is still a form)
import sys

import yaml


def die(code, message):
    print(f"project-area-options: {message}", file=sys.stderr)
    sys.exit(code)


def find_area_field(doc):
    if not isinstance(doc, dict):
        # A form whose top-level YAML parses but isn't a mapping (a bare list, a scalar) has no
        # `body:` to look in — treated the same as "no dropdown field with id: area" (exit 3),
        # not an uncaught AttributeError from `.get()` on a list/str outside the 0/2/3 contract.
        return None
    for entry in doc.get("body") or []:
        if isinstance(entry, dict) and entry.get("id") == "area" and entry.get("type") == "dropdown":
            return entry
    return None


def line_indent(line):
    return len(line) - len(line.lstrip(" "))


def enclosing_list_item_indent(lines, idx):
    """Indent of the nearest preceding `- ...` marker with LESS indent than lines[idx].

    `id: area` and `options:` are siblings several keys apart (id, attributes, then attributes'
    OWN children label/description/options), so bounding the forward scan by `id: area`'s own
    indent breaks on the very first sibling key. The real boundary of "this field" is the
    enclosing `- type: dropdown` list item, one level up.
    """
    target_indent = line_indent(lines[idx])
    for i in range(idx - 1, -1, -1):
        stripped = lines[i].strip()
        if not stripped:
            continue
        indent = line_indent(lines[i])
        if indent < target_indent and stripped.startswith("- "):
            return indent
    return None


def main():
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", newline="\n")

    if len(sys.argv) < 3:
        die(2, "usage: project-area-options.py <form.yml> <area-label>...")

    form_path, labels = sys.argv[1], sys.argv[2:]

    try:
        with open(form_path, encoding="utf-8") as handle:
            text = handle.read()
    # UnicodeDecodeError too, not just OSError: it is a ValueError, not an OSError, and a form
    # that is not valid UTF-8 would otherwise raise past this into an uncaught traceback — exit 1,
    # outside this script's own documented 0/2/3 contract.
    except (OSError, UnicodeDecodeError) as exc:
        die(2, f"cannot read {form_path}: {exc}")

    try:
        doc = yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:
        die(2, f"{form_path} is not valid YAML: {exc}")

    if find_area_field(doc) is None:
        die(3, f"{form_path} has no dropdown field with id: area")

    lines = text.split("\n")

    id_idx = next((i for i, line in enumerate(lines) if line.strip() == "id: area"), None)
    if id_idx is None:
        die(3, f"{form_path}: 'id: area' is not its own line — cannot locate it textually")

    item_indent_bound = enclosing_list_item_indent(lines, id_idx)
    if item_indent_bound is None:
        die(3, f"{form_path}: 'id: area' is not inside a '- ' list item — cannot bound its field")

    # Scan forward from `id: area` for its `options:` line, staying inside the enclosing list
    # item (a line at or below item_indent_bound means we left it: the next field, or EOF).
    options_idx = None
    for i in range(id_idx + 1, len(lines)):
        stripped = lines[i].strip()
        if stripped == "":
            continue
        if line_indent(lines[i]) <= item_indent_bound:
            break
        if stripped == "options:":
            options_idx = i
            break
    if options_idx is None:
        die(3, f"{form_path}: the area field has no 'options:' line in the expected shape")
    options_indent = line_indent(lines[options_idx])

    # The options list runs while lines are more indented than `options:` itself and look like
    # a sequence item; the first line that is not — a sibling key, a dedent, end of file — ends it.
    item_start = options_idx + 1
    item_end = item_start
    while item_end < len(lines):
        stripped = lines[item_end].strip()
        if stripped.startswith("- ") and line_indent(lines[item_end]) > options_indent:
            item_end += 1
            continue
        break

    if item_end == item_start:
        die(3, f"{form_path}: the 'options:' list under id: area is empty or not the expected shape")

    item_indent = line_indent(lines[item_start])
    new_items = [f'{" " * item_indent}- "{_escape(label)}"' for label in labels]

    new_lines = lines[:item_start] + new_items + lines[item_end:]

    try:
        with open(form_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(new_lines))
    except OSError as exc:
        die(2, f"cannot write {form_path}: {exc}")

    sys.exit(0)


def _escape(label):
    # \\ first, so the backslashes this introduces for \n/\r/\t are never themselves re-escaped.
    # A label reaching here can carry a real control character (parse-manifest.py only forbids an
    # embedded TAB; a YAML double-quoted scalar like "area: foo\nbar" decodes \n to an actual
    # newline) — left unescaped, it would land as a raw newline inside a generated double-quoted
    # scalar and corrupt the form's YAML instead of producing an invalid-but-contained string.
    return (
        label.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


if __name__ == "__main__":
    main()
