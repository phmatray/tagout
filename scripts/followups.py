#!/usr/bin/env python3
"""Agrège les suivis ouverts des migrations, et donne aux décisions propriétaire une sortie
questionnaire (rendu) + un chemin de réponse (ingestion).

Sources de vérité : le `migration/report.json` de chaque repo migré (clés `next_steps`
et `deferred`) et, en option, le backlog du kit (`--backlog docs/backlog.md`). Le mode
d'agrégation par défaut (aucun flag `--questionnaire`/`--ingest`) reste en lecture seule ; les
mises à jour se font dans les rapports eux-mêmes, à la source, via les protocoles du skill
`review-followups` — ce que `--ingest` applique désormais mécaniquement pour les décisions propriétaire.

Usage :
  followups.py <repo> [<repo>…] [--backlog <fichier.md>] [--json]
  followups.py <repo> [<repo>…] --questionnaire <out.md> [--profile-todos <profil.md>…]
                       [--to "<nom>"] [--from "<nom>"] [--deadline "<texte>"]
  followups.py <repo> [<repo>…] --ingest <answered.md> [--dry-run]

Tri (mode agrégation) : décisions propriétaire d'abord, puis tâches par effort croissant
(« ~10 min » < « ~1 h » < sans effort), avec provenance (repo) partout.

Le mode questionnaire porte le gabarit *discovery questionnaire* de Matt Pocock
(`mattpocock/skills`, `productivity/to-questionnaire`, MIT) : Purpose / From-To-How-used / Context /
How to answer / un thème `##` par groupe / une question `### ` par idée avec un stub de réponse
`>` — ici appliqué aux décisions propriétaire (`owner: true`) et, en option, aux marqueurs
`<!-- TODO: … -->` d'un profil de repo.
"""
import argparse
import hashlib
import json
import re
import sys
from datetime import date
from pathlib import Path


def parse_effort_minutes(effort):
    """« ~10 min » → 10 ; « ~1 h » → 60 ; illisible/absent → None (classé en dernier)."""
    if not effort:
        return None
    m = re.search(r'(\d+(?:[.,]\d+)?)\s*(min|h)', effort)
    if not m:
        return None
    value = float(m.group(1).replace(',', '.'))
    return value * 60 if m.group(2) == 'h' else value


def repo_name(p):
    """Le NOM rapporté (`repo` dans le JSON) : celui que l'appelant a TAPÉ, jamais celui que
    `.resolve()` rendrait après avoir suivi un lien symbolique — même règle, même issue #143, que
    `REPO_NAME` dans audit-inventory.sh (voir son commentaire pour le raisonnement complet). Un
    `p.resolve().name` nommerait la CIBLE d'un `repo` symlinké plutôt que l'argument.

    `.` et `..` sont l'exception : ce sont des RÉFÉRENCES, pas des noms — `Path(...).name` y vaut
    `''` (`.`) ou le littéral `'..'`, jamais le vrai nom du répertoire. L'appel le plus courant de
    tous (un agent déjà dans le dépôt, lançant `followups.py .`) est justement celui-là, donc ce
    cas retombe sur `.resolve().name` comme avant.
    """
    name = p.name
    return name if name and name != '..' else p.resolve().name


def resolve_repo_root(repo):
    """(nom rapporté, racine résolue) pour un argument `repo` — même règle de résolution que
    `load_repo`, factorisée pour être réutilisée par le mode ingestion."""
    p = Path(repo)
    base = Path.cwd()
    root = p if p.is_absolute() else base / p
    return repo_name(p), root, base, p.is_absolute()


def load_repo(repo):
    # Le chemin AFFICHÉ doit être celui contre lequel `repo` a réellement été résolu, sinon un
    # « introuvable » nomme un chemin que personne n'a tapé sans un mot sur d'où il sort (#49). Un
    # chemin absolu n'a été résolu contre rien, la clause serait un mensonge (cf. resolution_hint()
    # dans report-dashboard.py, dont le GABARIT est repris ici — sans sa clause propre au
    # report.json, puisque la base ici est le cwd, pas le répertoire d'un rapport).
    name, root, base, is_absolute = resolve_repo_root(repo)
    path = root / 'migration' / 'report.json'
    if not path.is_file():
        hint = '' if is_absolute else f' (chemin relatif résolu depuis {base})'
        return {'repo': name, 'error': f'{path} introuvable{hint}', 'next_steps': [], 'deferred': []}
    r = json.loads(path.read_text(encoding='utf-8'))
    steps = [{'repo': name, 'text': s.get('text', ''), 'effort': s.get('effort'),
              'owner': bool(s.get('owner')), 'effortMinutes': parse_effort_minutes(s.get('effort')),
              'answer': s.get('answer'), 'answered': s.get('answered')}
             for s in r.get('next_steps', [])]
    deferred = [{'repo': name, 'title': d.get('strong', ''), 'text': d.get('text', '')}
                for d in r.get('deferred', [])]
    return {'repo': name, 'app': r.get('app', name), 'report': str(path),
            'next_steps': steps, 'deferred': deferred}


def load_backlog(path):
    """Backlog du kit : entrées `- **Titre** : texte` avec leur déclencheur inline."""
    entries = []
    for m in re.finditer(r'^- \*\*(.+?)\*\*\s*:?\s*(.*(?:\n  .*)*)', Path(path).read_text(encoding='utf-8'), re.M):
        entries.append({'title': m.group(1).strip(), 'text': ' '.join(m.group(2).split())})
    return entries


# --------------------------------------------------------------------------------- questionnaire

def entry_id(repo, text):
    """Identifiant stable d'une entrée (décision propriétaire ou TODO de profil) : un hash court de
    son repo/fichier d'origine et de son texte exact. Change si l'entrée est reformulée — c'est
    voulu : `--ingest` doit alors la signaler comme périmée plutôt que d'apparier au hasard une
    réponse à une question qui n'est plus celle posée."""
    return hashlib.sha1(f'{repo}\n{text}'.encode('utf-8')).hexdigest()[:8]


TODO_RE = re.compile(r'<!--\s*TODO:\s*(.*?)\s*-->', re.S)


def read_profile_todos(path):
    """Les marqueurs `<!-- TODO: … -->` d'un profil de repo (`init`), dans l'ordre où
    ils apparaissent."""
    text = Path(path).read_text(encoding='utf-8')
    return TODO_RE.findall(text)


def render_questionnaire(repos, profile_todo_paths, to, frm, deadline):
    """Rend les décisions propriétaire (`owner: true`) et, en option, les TODO d'un profil de
    repo, dans le gabarit *discovery questionnaire* porté de `mattpocock/skills`
    (`productivity/to-questionnaire`, MIT — voir le docstring du module).

    Renvoie (texte_markdown, avertissements) — un avertissement par collision d'id détectée (deux
    entrées au texte identique dans le même repo)."""
    by_repo = [(r['repo'], r.get('app', r['repo']), [s for s in r['next_steps'] if s['owner']])
               for r in repos]
    with_decisions = [(repo, app, entries) for repo, app, entries in by_repo if entries]
    total = sum(len(entries) for _, _, entries in with_decisions)
    apps = ', '.join(r.get('app', r['repo']) for r in repos) or 'aucun repo'

    warnings = []
    lines = [f'# Open decisions — {apps}', '']
    lines.append(
        f'**Purpose:** {total} follow-up(s) across {len(repos)} migrated repo(s) are waiting on a '
        'decision only you can make; each answer closes, defers or records one at its source.')
    lines.append('')
    lines.append(
        f'**From:** {frm}, **To:** {to}, **How your answers will be used:** '
        '`followups.py --ingest` applies them to each repo\'s migration/report.json and '
        'report.md; the agent then regenerates the dashboard and commits.')
    lines.append('')
    lines.append('## Context')
    lines.append('')
    repo_list = ', '.join(repo for repo, _, _ in with_decisions) or 'none'
    lines.append(
        f'{total} decision(s) across {len(with_decisions)} repo(s) ({repo_list}) are waiting on '
        f'you, generated {date.today().isoformat()} from each repo\'s migration/report.json '
        '`next_steps` entries marked `owner: true`.')
    lines.append('')
    lines.append('## How to answer')
    lines.append('')
    lines.append(
        f'Deadline: {deadline or "none"}. Under each question write one of `done` (already '
        'handled), `wont` (not pursued — say why if you like), `later` (keep it open; your note '
        'is recorded), or anything else. Partial answers and "I don\'t know" are useful; flag '
        'doubt rather than skipping.')
    lines.append('')

    seen_ids = set()
    for repo, app, entries in with_decisions:
        lines.append(f'## {app}')
        lines.append('')
        for s in entries:
            eid = entry_id(repo, s['text'])
            if eid in seen_ids:
                warnings.append(
                    f'collision: duplicate id {eid} in {repo} (identical entry text) — only the '
                    'first is answerable')
            seen_ids.add(eid)
            lines.append(f'### {s["text"]}')
            lines.append('')
            effort = s.get('effort') or 'no effort estimate'
            lines.append(f'_Why this matters: {effort}._')
            lines.append('')
            if s.get('answer'):
                # « later » garde la décision ouverte À DESSEIN (voir "How to answer") — mais sans
                # ce rappel, un futur rendu repose la même question sans jamais montrer que le
                # propriétaire y a déjà répondu une fois.
                lines.append(f'_Previously answered ({s.get("answered") or "date unknown"}): '
                             f'"{s["answer"]}"._')
                lines.append('')
            lines.append(f'<!-- followup: {repo} | {eid} -->')
            lines.append('>')
            lines.append('')

    if profile_todo_paths:
        lines.append('## Repo profile')
        lines.append('')
        seen_todo_ids = set()
        for path in profile_todo_paths:
            for todo in read_profile_todos(path):
                pid = entry_id(str(path), todo)
                if pid in seen_todo_ids:
                    warnings.append(
                        f'collision: duplicate id {pid} in {path} (identical TODO text) — only '
                        'the first is answerable')
                seen_todo_ids.add(pid)
                lines.append(f'### {todo}')
                lines.append('')
                lines.append(f'<!-- profile-todo: {path} | {pid} -->')
                lines.append('>')
                lines.append('')

    lines.append('## Anything else?')
    lines.append('')
    lines.append('>')
    lines.append('')
    return '\n'.join(lines), warnings


def run_questionnaire(repo_args, profile_todo_paths, to, frm, deadline, out_path):
    repos = [load_repo(r) for r in repo_args]
    errors = [r for r in repos if r.get('error')]
    for r in errors:
        print(f"⚠ {r['error']}")

    text, warnings = render_questionnaire(repos, profile_todo_paths, to, frm, deadline)
    Path(out_path).write_text(text, encoding='utf-8')

    for w in warnings:
        print(w)
    n_owner = sum(1 for r in repos for s in r['next_steps'] if s['owner'])
    print(f'Wrote {out_path}: {n_owner} owner decision(s) across {len(repos)} repo(s).')
    return 1 if errors else 0


# ------------------------------------------------------------------------------------------ ingest

MARKER_RE = re.compile(r'<!--\s*(followup|profile-todo):\s*(.+?)\s*\|\s*([0-9a-f]{8})\s*-->')


def parse_answers(md_text):
    """Lit un fichier de réponses : pour chaque marqueur `<!-- followup: … -->` /
    `<!-- profile-todo: … -->`, capture le bloc `>` qui suit, trimmé. Un stub resté vide (pas de
    texte après `>`) n'est pas une réponse. Renvoie (followups, profile_todos), chacun
    id -> (origine, texte_réponse)."""
    lines = md_text.splitlines()
    followups = {}
    profile_todos = {}
    i = 0
    n = len(lines)
    while i < n:
        m = MARKER_RE.search(lines[i])
        if not m:
            i += 1
            continue
        kind, origin, eid = m.group(1), m.group(2), m.group(3)
        j = i + 1
        answer_parts = []
        while j < n and lines[j].startswith('>'):
            content = lines[j][1:].strip()
            if content:
                answer_parts.append(content)
            j += 1
        answer = ' '.join(answer_parts).strip()
        if answer:
            target = followups if kind == 'followup' else profile_todos
            target[eid] = (origin, answer)
        i = j
    return followups, profile_todos


def tick_report_md_line(report_md, old_line, new_line):
    """Remplace la PREMIÈRE ligne dont le contenu (indentation mise à part) égale exactement
    `old_line`, par `new_line` (indentation conservée). Un test par SOUS-CHAÎNE tickerait la
    première ligne qui ne fait que COMMENCER par le même texte qu'une autre plus longue
    (« - [ ] Update SDK » à l'intérieur de « - [ ] Update SDK version pin in csproj ») — ce test
    par LIGNE ENTIÈRE ne peut matcher que la ligne qui EST la case à cocher, jamais un préfixe
    d'une autre. Renvoie (texte, apparié)."""
    lines = report_md.split('\n')
    for i, line in enumerate(lines):
        if line.strip() == old_line:
            indent = line[:len(line) - len(line.lstrip())]
            lines[i] = indent + new_line
            return '\n'.join(lines), True
    return report_md, False


def apply_answer(report, report_md, entry, answer, today):
    """Applique une réponse à une entrée `next_steps` (mutée en place dans `report`), selon le
    premier mot de la réponse : `done` (supprimée), `wont`/`no`/`never` (déplacée vers `deferred`),
    tout le reste (`later` inclus) — conservée, annotée `answer`/`answered`. Renvoie
    (outcome, report_md_mis_à_jour, md_apparié) — `md_apparié` est None quand `report_md` est
    absent, sinon True/False selon que la ligne à cocher a été trouvée."""
    text = entry.get('text', '')
    stripped = answer.strip()
    m = re.match(r'(\S+)', stripped)
    first = m.group(1).lower().rstrip('.,;:') if m else ''
    md_matched = None if report_md is None else False

    if first == 'done':
        report['next_steps'] = [s for s in report['next_steps'] if s is not entry]
        outcome = 'done'
        if report_md is not None:
            report_md, md_matched = tick_report_md_line(
                report_md, f'- [ ] {text}', f'- [x] {text}')
    elif first in ('wont', 'no', 'never'):
        report['next_steps'] = [s for s in report['next_steps'] if s is not entry]
        rest = stripped[len(m.group(1)):].strip(' ,.-—:') if m else ''
        new_text = f'{text} — {rest}' if rest else text
        report.setdefault('deferred', []).append(
            {'strong': f'Not pursued by decision ({today})', 'text': new_text})
        outcome = 'wont'
        if report_md is not None:
            report_md, md_matched = tick_report_md_line(
                report_md, f'- [ ] {text}', f'- [x] ~~{text}~~ — not pursued by decision')
    else:
        entry['answer'] = stripped
        entry['answered'] = today
        outcome = 'recorded'

    return outcome, report_md, md_matched


def run_ingest(repo_args, answered_path, dry_run):
    try:
        md_text = Path(answered_path).read_text(encoding='utf-8')
    except OSError as e:
        print(f'malformed answered file: cannot read {answered_path}: {e}', file=sys.stderr)
        return 2
    if not md_text.strip():
        print(f'malformed answered file: {answered_path} is empty', file=sys.stderr)
        return 2

    followups, profile_todos = parse_answers(md_text)
    today = date.today().isoformat()
    kit_root = Path(__file__).resolve().parent.parent

    passed = {}
    errors = []
    for r in repo_args:
        name, root, base, is_absolute = resolve_repo_root(r)
        report_path = root / 'migration' / 'report.json'
        if not report_path.is_file():
            hint = '' if is_absolute else f' (chemin relatif résolu depuis {base})'
            errors.append(f'{report_path} introuvable{hint}')
            continue
        passed[name] = root
    for e in errors:
        print(f'⚠ {e}')

    by_repo = {}
    for eid, (origin, answer) in followups.items():
        by_repo.setdefault(origin, {})[eid] = answer

    stale = []
    collisions = []
    md_misses = []

    for name, root in passed.items():
        report_path = root / 'migration' / 'report.json'
        md_path = root / 'migration' / 'report.md'
        report = json.loads(report_path.read_text(encoding='utf-8'))
        report.setdefault('deferred', [])
        report_md_text = md_path.read_text(encoding='utf-8') if md_path.is_file() else None

        id_to_entries = {}
        for s in report.get('next_steps', []):
            if not s.get('owner'):
                continue
            id_to_entries.setdefault(entry_id(name, s.get('text', '')), []).append(s)

        answers_for_repo = by_repo.get(name, {})
        counts = {'done': 0, 'wont': 0, 'recorded': 0, 'unanswered': 0, 'stale': 0}
        any_applied = False

        for eid, matches in id_to_entries.items():
            if eid not in answers_for_repo:
                counts['unanswered'] += len(matches)
                continue
            if len(matches) > 1:
                collisions.append(
                    f'collision: id {eid} in {name} matches {len(matches)} entries with '
                    'identical text — answer applied to the first only')
            outcome, report_md_text, md_matched = apply_answer(
                report, report_md_text, matches[0], answers_for_repo[eid], today)
            counts[outcome] += 1
            any_applied = True
            if md_matched is False:
                md_misses.append(
                    f"{name}: report.md has no matching checkbox line for {matches[0].get('text', '')!r}")

        for eid in answers_for_repo:
            if eid not in id_to_entries:
                stale.append(
                    f'stale id {eid} in {name}: no matching next_steps entry (reworded since '
                    'the questionnaire?)')
                counts['stale'] += 1

        # Rien à appliquer cette fois -> AUCUNE écriture, même pas un round-trip JSON/report.md
        # inoffensif en apparence : ça produirait un diff (indentation, fin de ligne normalisée)
        # sur un repo que cette ingestion n'a, en réalité, pas touché.
        if not dry_run and any_applied:
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            if report_md_text is not None:
                md_path.write_text(report_md_text, encoding='utf-8')

        print(f"{name}: {counts['done']} done · {counts['wont']} not pursued · "
              f"{counts['recorded']} recorded · {counts['unanswered']} unanswered · "
              f"{counts['stale']} stale")
        if not dry_run and any_applied:
            print(f'  python3 "{kit_root}/scripts/report-dashboard.py" {report_path}')
            print(f'  git -C "{root}" commit -am "chore: follow-up closed — see report.md"')

    for origin, answers in by_repo.items():
        if origin not in passed:
            for eid in answers:
                stale.append(f'stale id {eid} in {origin}: repo not passed to --ingest')

    for s in stale:
        print(s)
    for c in collisions:
        print(c)
    for m in md_misses:
        print(m)

    if profile_todos:
        print('Repo profile answers (not written — edit the profile):')
        for path, answer in profile_todos.values():
            print(f'  {path}: {answer}')

    return 1 if errors else 0


def main():
    sys.stdout.reconfigure(encoding='utf-8', newline='\n')

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('repos', nargs='+', help='répertoires des repos migrés')
    ap.add_argument('--backlog', help='backlog du kit (docs/backlog.md)')
    ap.add_argument('--json', action='store_true', dest='as_json')
    ap.add_argument('--questionnaire', help="écrit un discovery questionnaire vers ce fichier")
    ap.add_argument('--profile-todos', nargs='*', default=[],
                     help='profils de repo dont les marqueurs <!-- TODO: --> deviennent des questions')
    ap.add_argument('--to', default='the repository owner')
    ap.add_argument('--from', dest='frm', default='tagout followups')
    ap.add_argument('--deadline', default=None)
    ap.add_argument('--ingest', help='fichier de réponses à appliquer à la source')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    if args.questionnaire and args.ingest:
        print('--questionnaire and --ingest are mutually exclusive', file=sys.stderr)
        return 1

    if args.ingest:
        return run_ingest(args.repos, args.ingest, args.dry_run)

    if args.questionnaire:
        return run_questionnaire(args.repos, args.profile_todos, args.to, args.frm,
                                  args.deadline, args.questionnaire)

    repos = [load_repo(r) for r in args.repos]
    errors = [r for r in repos if r.get('error')]
    steps = [s for r in repos for s in r['next_steps']]
    owner = [s for s in steps if s['owner']]
    tasks = sorted((s for s in steps if not s['owner']),
                   key=lambda s: (s['effortMinutes'] is None, s['effortMinutes'] or 0))
    deferred = [d for r in repos for d in r['deferred']]
    backlog = load_backlog(args.backlog) if args.backlog else []

    if args.as_json:
        json.dump({'ownerDecisions': owner, 'tasks': tasks, 'deferred': deferred,
                   'kitBacklog': backlog, 'errors': [r['error'] for r in errors]},
                  sys.stdout, ensure_ascii=False, indent=2)
        print()
        return 1 if errors else 0

    print(f"# Suivis ouverts — {len(owner)} décision(s) propriétaire · "
          f"{len(tasks)} tâche(s) · {len(deferred)} différé(s) assumé(s)\n")
    for e in errors:
        print(f"⚠ {e['error']}")

    if owner:
        print("## Décisions propriétaire — n'attendent que vous\n")
        print("| Repo | Décision | Effort |")
        print("|---|---|---|")
        for s in owner:
            note = f" _(noté {s['answered']})_" if s.get('answer') else ''
            print(f"| {s['repo']} | {s['text']}{note} | {s['effort'] or '—'} |")
        print()

    if tasks:
        print("## Tâches prêtes — par effort croissant\n")
        print("| Repo | Tâche | Effort |")
        print("|---|---|---|")
        for s in tasks:
            print(f"| {s['repo']} | {s['text']} | {s['effort'] or '—'} |")
        print()

    if backlog:
        print("## Backlog du kit — dettes à déclencheur (YAGNI)\n")
        for entry in backlog:
            print(f"- **{entry['title']}** : {entry['text']}")
        print()

    if deferred:
        print("## Différés assumés — pour mémoire, aucune action attendue\n")
        for d in deferred:
            print(f"- `{d['repo']}` — **{d['title']}** : {d['text']}")
        print()

    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
