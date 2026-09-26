---
title: Home
nav_order: 1
---

{%- assign plugin_hosts = site.data.hosts | where: "tier", "plugin" -%}
{%- assign rule_hosts = site.data.hosts | where: "tier", "rules" -%}
{%- assign rule_example = rule_hosts | first -%}
{%- assign claude_code = site.data.hosts | where: "id", "claude-code" | first -%}

<section class="kit-hero" aria-labelledby="kit-hero-title">
<article class="kit-tag kit-hero-tag">
<span class="kit-grommet" aria-hidden="true"></span>
<div class="kit-tag-band"><h1 id="kit-hero-title" class="kit-tag-band-title kit-hero-title">Tagout</h1></div>
<div class="kit-tag-body">
<p class="kit-hero-lead"><strong>The gate-verified issue → pull request lifecycle for coding agents: no green tag, no merge.</strong> An idea becomes a planned issue, the issue a pull request, the pull request lands, hands-off. Every step runs behind a gate that refuses by name, saying who locked it and what clears it.</p>
<dl class="kit-fields kit-plugins" aria-label="The two plugins">
<dt><code>tagout</code></dt><dd>The issue → PR lifecycle, for any GitHub repository in any language. No .NET, no MCP server. <code>{{ claude_code.install[1] }}</code></dd>
<dt><code>tagout-migrate</code></dt><dd>The add-on for a legacy .NET application: the seven-phase <code>/migrate</code> pipeline to verified production. Needs RoselineMCP (.NET 10 SDK). <code>{{ claude_code.install[2] }}</code></dd>
</dl>
<div class="kit-denial" role="group" aria-label="A refusal as the gate writes it">
<p class="kit-denial-title"><span>Refusal, as written by the gate</span><span>hooks/roseline-gate.sh</span></p>
<dl class="kit-fields">
<dt>Locked by</dt><dd><code>roseline-gate.sh</code></dd>
<dt>On</dt><dd><code>Read</code> of <code>Program.cs</code></dd>
<dt>Reason</dt><dd>Program.cs is C#, and this kit routes all C# analysis through RoselineMCP.</dd>
<dt>Use instead</dt><dd><code>mcp__roseline__search_symbols</code> for the file's shape, <code>mcp__roseline__get_symbol_info</code> to read one member's body.</dd>
</dl>
</div>
<p class="kit-hero-actions" markdown="span">[Read the methodology](methodology.md) [Why the gate exists](roseline-gate.md) [Source on GitHub](https://github.com/phmatray/tagout)</p>
</div>
</article>

<aside class="kit-tag kit-install" aria-labelledby="kit-install-title">
<span class="kit-grommet" aria-hidden="true"></span>
<div class="kit-tag-band"><h2 id="kit-install-title" class="kit-tag-band-title">Install on your agent</h2></div>
<div class="kit-tag-body">
<p class="kit-install-hint">Pick the host you are in. The command is the whole install.</p>
<div class="kit-picker">
{%- for host in plugin_hosts %}
<input type="radio" name="kit-host" id="kit-host-{{ host.id }}"{% if forloop.first %} checked{% endif %}>
{%- endfor %}
<input type="radio" name="kit-host" id="kit-host-rules">
<div class="kit-picker-tabs" role="group" aria-label="Hosts">
{%- for host in plugin_hosts %}
<label class="kit-chip" for="kit-host-{{ host.id }}">{{ host.name }}</label>
{%- endfor %}
<label class="kit-chip" for="kit-host-rules">Other hosts</label>
</div>
<div class="kit-picker-panels">
{%- for host in plugin_hosts %}
<div class="kit-picker-panel">
<div class="language-bash highlighter-rouge"><div class="highlight"><pre class="highlight"><code>{{ host.install | join: "
" | xml_escape }}</code></pre></div></div>
<div class="kit-picker-then">{{ host.then | markdownify }}</div>
</div>
{%- endfor %}
<div class="kit-picker-panel">
<div class="language-bash highlighter-rouge"><div class="highlight"><pre class="highlight"><code>{{ rule_example.install | join: "
" | xml_escape }}</code></pre></div></div>
<div class="kit-picker-then"><p>That second line is {{ rule_example.name }}'s; the other {{ rule_hosts.size | minus: 1 }} rule-file hosts have theirs on the <a href="{{ 'install.html' | relative_url }}">Install</a> page.</p></div>
</div>
</div>
</div>
<p class="kit-install-more" markdown="span">Written for Claude Code; a plugin on {{ plugin_hosts.size }} hosts, a rule file on {{ rule_hosts.size }} more families. Every host, and how to remove it: [Install](install.md). What each one gets: [Platforms](platforms.md). On Claude Code the lifecycle and the .NET add-on install separately; on every other host the manifest ships both. The add-on needs RoselineMCP, started by <code>dnx</code> from the .NET 10 SDK.</p>
</div>
</aside>
</section>

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

<section class="kit-section" aria-labelledby="kit-refusals-title">
<div class="kit-section-head"><h2 id="kit-refusals-title" class="kit-section-title">What the gates refuse</h2><p>Five ways an agent-driven upgrade goes wrong without anyone noticing, and the lock that stops each one.</p></div>
<ul class="kit-refusals">
<li><span class="kit-refusal-mark" aria-hidden="true"></span><p class="kit-refusal-without">Upgrading means bumping the target framework and hoping.</p><p class="kit-refusal-stop">Seven phases, each ending at a build, test and diagnostics gate. A red gate stops the pipeline.</p></li>
<li><span class="kit-refusal-mark" aria-hidden="true"></span><p class="kit-refusal-without">The agent reads whole C# files instead of asking Roslyn.</p><p class="kit-refusal-stop">The roseline gate denies a <code>Read</code> of a <code>.cs</code> file and names the RoselineMCP tool that replaces it.</p></li>
<li><span class="kit-refusal-mark" aria-hidden="true"></span><p class="kit-refusal-without">Four agents share one checkout, and a commit lands in another agent's pull request.</p><p class="kit-refusal-stop">Guarded git writes check the branch before and after, and the write-gate denies the raw command.</p></li>
<li><span class="kit-refusal-mark" aria-hidden="true"></span><p class="kit-refusal-without">The fix ships before the cause is known.</p><p class="kit-refusal-stop"><code>debug-issue</code> finds the root cause before any patch.</p></li>
<li><span class="kit-refusal-mark" aria-hidden="true"></span><p class="kit-refusal-without">The backlog only ever fills.</p><p class="kit-refusal-stop">One filing bar for every inlet, and <code>triage-backlog</code> to re-decide what is already open.</p></li>
</ul>
</section>

<section class="kit-section" aria-labelledby="kit-commands-title">
<div class="kit-section-head"><h2 id="kit-commands-title" class="kit-section-title">Which command?</h2><p>Once installed, say what you have. Each row is a skill or a command, and each one ends with a recap and the next command to type.</p></div>
<table class="kit-commands">
<thead><tr><th scope="col">Situation</th><th scope="col">Reach for</th></tr></thead>
<tbody>
<tr><td>An idea to track</td><td><code>create-issue</code></td></tr>
<tr><td>An issue with a plan</td><td><code>implement-issue #N</code></td></tr>
<tr><td>A PR to land</td><td><code>merge-pr #N</code></td></tr>
<tr><td>One idea or issue to a merged PR, hands-off</td><td><code>deliver-issue &lt;idea&gt;</code> or <code>#N</code></td></tr>
<tr><td>A queue that never shrinks</td><td><code>triage-backlog</code></td></tr>
<tr><td>Many issues, hands-off</td><td><code>auto-dev</code></td></tr>
<tr><td>What went wrong in my last sessions</td><td><code>review-sessions</code></td></tr>
<tr><td>A legacy .NET app</td><td><code>/migrate-assess</code>, then <code>/migrate</code></td></tr>
<tr><td>A migrated app to re-verify</td><td><code>/migrate-verify</code></td></tr>
<tr><td>A portfolio to cost</td><td><code>/migrate-audit</code></td></tr>
<tr><td>Open follow-ups across migrated repos</td><td><code>/migrate-followups</code></td></tr>
<tr><td>A new repo for these skills</td><td><code>profile-repo</code>, then <code>setup-repo</code></td></tr>
<tr><td>Something is already broken</td><td><code>debug-issue</code> fires on its own</td></tr>
</tbody>
</table>
</section>

<section class="kit-section" aria-labelledby="kit-siteindex-title">
<div class="kit-section-head"><h2 id="kit-siteindex-title" class="kit-section-title">The rest of the site</h2><p>The method in full, the decisions behind it, and one article per release.</p></div>
<ul class="kit-siteindex">
<li markdown="span">[The methodology](methodology.md)<span>The two loops in full, one page per skill, the machinery, and how the kit compares to GSD, SpecKit and BMAD.</span></li>
<li markdown="span">[Decisions](decisions.md)<span>Control-flow decisions have one program and one home.</span></li>
<li markdown="span">[Architectural Decision Records](adr/README.md)<span>The decisions that are hard to reverse, and the ones declined.</span></li>
<li markdown="span">[The roseline gate](roseline-gate.md)<span>Why every C# read and write goes through RoselineMCP.</span></li>
<li markdown="span">[The bundle gate](bundle-gate.md)<span>The opt-in drift gate for committed bundles.</span></li>
<li markdown="span">[Demo walkthrough](demo-walkthrough.md)<span>A real pipeline run on the bundled legacy fixture.</span></li>
<li markdown="span">[Journal](journal/index.md)<span>One article per release: why it happened, what got cut, what bit us.</span></li>
<li markdown="span">[Platforms](platforms.md)<span>What each host gets: skills, commands, MCP servers, gates, sub-agents.</span></li>
</ul>
</section>
