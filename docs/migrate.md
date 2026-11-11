---
title: .NET add-on
nav_order: 2.5
---

{%- assign claude_code = site.data.hosts | where: "id", "claude-code" | first -%}

# .NET add-on

`tagout-migrate` takes a legacy .NET application to verified production with the seven-phase `/migrate` pipeline. RoselineMCP does every C# analysis and edit, so it needs the .NET 10 SDK. It installs next to `tagout`, the issue → pull request lifecycle:

```bash
{{ claude_code.install | join: "
" }}
```

<section class="kit-hasp" aria-label="The migration pipeline as a group lock-out">
<div class="kit-hasp-bar">
<div class="kit-hasp-label"><dl class="kit-hasp-times" aria-label="Cleared, timed from the gate commits"><dt>Chords</dt><dd>18 min</dd><dt>Les Fleurs du Mal</dt><dd>~30 min</dd><dt>Pokédex G</dt><dd>~1 h</dd></dl><p class="kit-display">Seven locks, one hasp</p></div>
{%- assign phases = "assess|read-only audit,baseline|tests and diagnostics recorded,retarget|target framework moved,remediate|errors and warnings cleared,modernize|safe idioms applied,verify|build and tests green,deliver|report and release" | split: "," -%}
{%- for phase in phases %}{% assign bits = phase | split: "|" %}
<div class="kit-lock">
<svg viewBox="0 0 44 56" aria-hidden="true" focusable="false"><path class="shackle" d="M12 26V16a10 10 0 0 1 20 0v10"/><rect class="body" x="4" y="26" width="36" height="28" rx="2"/><circle class="keyway" cx="22" cy="38" r="3.2"/><rect class="keyway" x="20.6" y="39" width="2.8" height="7" rx="1"/></svg>
<span class="kit-lock-name">{{ bits[0] }}</span>
<span class="kit-lock-gate">{{ bits[1] }}</span>
</div>
{%- endfor %}
</div>
</section>

<section class="kit-section" aria-labelledby="kit-record-title">
<div class="kit-section-head"><h2 id="kit-record-title" class="kit-section-title">Lock-out record: four dead platforms, cleared</h2><p>Four apps from 2013–2016, built for platforms nothing runs any more, were audited, migrated to Blazor WebAssembly and verified live: characterization tests first, legacy data and art byte for byte, measured WCAG AA, offline proven with the network cut. The minutes come from the gate commits, not a stopwatch.</p></div>
<table class="kit-record">
<thead><tr><th scope="col">App, live</th><th scope="col">Locked on</th><th scope="col">Cleared in</th></tr></thead>
<tbody>
<tr><td class="kit-record-app"><a href="https://phmatray.github.io/chords/">Chords</a></td><td class="kit-record-from">Windows Phone</td><td class="kit-record-time">18 min<small>pipeline, measured</small></td></tr>
<tr><td class="kit-record-app"><a href="https://phmatray.github.io/fleurs-du-mal/">Les Fleurs du Mal</a></td><td class="kit-record-from">WinRT 8.1</td><td class="kit-record-time">~30 min<small>pipeline, measured</small></td></tr>
<tr><td class="kit-record-app"><a href="https://phmatray.github.io/pokedex/">Pokédex G</a></td><td class="kit-record-from">UWP, SQLite 49 MB</td><td class="kit-record-time">~1 h<small>pipeline, measured</small></td></tr>
<tr><td class="kit-record-app"><a href="https://phmatray.github.io/sokoban/">Sokoban</a></td><td class="kit-record-from">WinRT 8.1</td><td class="kit-record-time is-untimed">First wave<small>not timed</small></td></tr>
</tbody>
</table>
<p class="kit-record-note" markdown="span">The audit, the per-app reports and what each wave taught the kit: [the case study](case-studies/winrt-portfolio/portfolio.md).</p>
</section>

<section class="kit-section" aria-labelledby="kit-denial-title">
<div class="kit-section-head"><h2 id="kit-denial-title" class="kit-section-title">A refusal, as the gate writes it</h2><p markdown="span">The roseline gate denies a `Read` of a C# file and names the tool that replaces it. [Why the gate exists](roseline-gate.md).</p></div>
<div class="kit-denial" role="group" aria-label="A refusal as the gate writes it">
<p class="kit-denial-title"><span>Refusal, as written by the gate</span><span>hooks/roseline-gate.sh</span></p>
<dl class="kit-fields">
<dt>Locked by</dt><dd><code>roseline-gate.sh</code></dd>
<dt>On</dt><dd><code>Read</code> of <code>Program.cs</code></dd>
<dt>Reason</dt><dd>Program.cs is C#, and this kit routes all C# analysis through RoselineMCP.</dd>
<dt>Use instead</dt><dd><code>mcp__roseline__search_symbols</code> for the file's shape, <code>mcp__roseline__get_symbol_info</code> to read one member's body.</dd>
</dl>
</div>
</section>

<section class="kit-section" aria-labelledby="kit-mrefusals-title">
<div class="kit-section-head"><h2 id="kit-mrefusals-title" class="kit-section-title">What the gates refuse</h2><p>Two ways an agent-driven upgrade goes wrong without anyone noticing, and the lock that stops each one.</p></div>
<ul class="kit-refusals">
<li><span class="kit-refusal-mark" aria-hidden="true"></span><p class="kit-refusal-without">Upgrading means bumping the target framework and hoping.</p><p class="kit-refusal-stop">Seven phases, each ending at a build, test and diagnostics gate. A red gate stops the pipeline.</p></li>
<li><span class="kit-refusal-mark" aria-hidden="true"></span><p class="kit-refusal-without">The agent reads whole C# files instead of asking Roslyn.</p><p class="kit-refusal-stop">The roseline gate denies a <code>Read</code> of a <code>.cs</code> file and names the RoselineMCP tool that replaces it.</p></li>
</ul>
</section>

<section class="kit-section" aria-labelledby="kit-mcommands-title">
<div class="kit-section-head"><h2 id="kit-mcommands-title" class="kit-section-title">Which command?</h2><p>Once installed, say what you have.</p></div>
<table class="kit-commands">
<thead><tr><th scope="col">Situation</th><th scope="col">Reach for</th></tr></thead>
<tbody>
<tr><td>A legacy .NET app</td><td><code>/migrate-assess</code>, then <code>/migrate</code></td></tr>
<tr><td>A migrated app to re-verify</td><td><code>/migrate-verify</code></td></tr>
<tr><td>A portfolio to cost</td><td><code>/migrate-audit</code></td></tr>
<tr><td>Open follow-ups across migrated repos</td><td><code>/migrate-followups</code></td></tr>
</tbody>
</table>
</section>

More: [a real pipeline run on the bundled legacy fixture](demo-walkthrough.md), and [the audit, the per-app reports and what each wave taught the kit](case-studies/winrt-portfolio/portfolio.md).
