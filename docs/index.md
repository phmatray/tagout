---
title: Home
nav_order: 1
---

{%- assign plugin_hosts = site.data.hosts | where: "tier", "plugin" -%}
{%- assign rule_hosts = site.data.hosts | where: "tier", "rules" -%}
{%- assign rule_example = rule_hosts | first -%}

<section class="kit-hero" aria-labelledby="kit-hero-title">
<article class="kit-tag kit-hero-tag">
<span class="kit-grommet" aria-hidden="true"></span>
<div class="kit-tag-band"><h1 id="kit-hero-title" class="kit-tag-band-title kit-hero-title">Tagout</h1></div>
<div class="kit-tag-body">
<p class="kit-hero-lead"><strong>Tagout takes an idea to a merged pull request while you do something else.</strong> Say what you want; your coding agent files the issue with a plan, builds it on a branch, opens the pull request, waits for CI and merges it. Every step is checked by a script that stops the agent when something is wrong and says what to fix.</p>
<p class="kit-hero-tagline">No green tag, no merge.</p>
<dl class="kit-fields kit-plugins" aria-label="The two plugins">
<dt><code>tagout</code></dt><dd>The issue → PR lifecycle, for any GitHub repository in any language. No .NET, no MCP server.</dd>
<dt><code>tagout-migrate</code></dt><dd>The add-on for a legacy .NET application: the seven-phase <code>/migrate</code> pipeline to verified production. Needs RoselineMCP (.NET 10 SDK). <a href="migrate.md">The .NET add-on</a>.</dd>
</dl>
<div class="kit-denial" role="group" aria-label="A refusal as the gate writes it">
<p class="kit-denial-title"><span>Refusal, as written by the gate</span><span>hooks/git-write-gate.sh</span></p>
<dl class="kit-fields">
<dt>Locked by</dt><dd><code>git-write-gate.sh</code></dd>
<dt>On</dt><dd><code>git commit</code>, the raw command</dd>
<dt>Reason</dt><dd>A bare commit does not check which branch HEAD is on — that is how #26 and #280 landed work on someone else's branch with exit 0.</dd>
<dt>Use instead</dt><dd><code>guarded-commit.sh -C &lt;worktree&gt; &lt;branch&gt; -- &lt;git commit args&gt;</code></dd>
</dl>
</div>
<p class="kit-hero-actions" markdown="span">[Read the methodology](methodology.md) [Source on GitHub](https://github.com/phmatray/tagout)</p>
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
<p class="kit-install-more" markdown="span">Every host, and how to remove it: [Install](install.md). What each one gets: [Platforms](platforms.md).</p>
</div>
</aside>
</section>

<section class="kit-section kit-run" aria-labelledby="kit-run-title">
<div class="kit-section-head"><h2 id="kit-run-title" class="kit-section-title">One run, start to finish</h2><p>One issue of this repository, from the idea to the merge. Its pull request was opened at 12:07:43 and merged at 12:24:27, {{ site.data.demo.opened_to_merged }} later. The three links are the proof.</p></div>
<ol class="kit-run-steps">
{%- for step in site.data.demo.steps %}
<li><code>{{ step.skill }}</code><a href="{{ step.url }}">{{ step.left }}</a><span class="kit-run-at">{{ step.at }}</span></li>
{%- endfor %}
</ol>
</section>

<section class="kit-section kit-figures" aria-labelledby="kit-figures-title">
<div class="kit-section-head"><h2 id="kit-figures-title" class="kit-section-title">The lifecycle, on this repository</h2><p>Tagout is built with Tagout. Read from this repository's tracker on {{ site.data.figures.as_of }} by <code>scripts/site-figures.py</code>.</p></div>
<dl class="kit-figures-list">
<div><dt>pull requests merged</dt><dd>{{ site.data.figures.prs_merged }}</dd></div>
<div><dt>issues delivered</dt><dd>{{ site.data.figures.issues_delivered }}</dd></div>
<div><dt>hours, issue filed to merged, median</dt><dd>{{ site.data.figures.median_issue_to_merge_hours }}</dd></div>
</dl>
<p markdown="span">[The auto-dev case study of this repository](case-studies/auto-dev/2026-10-28-tagout.md).</p>
</section>

<section class="kit-section" aria-labelledby="kit-refusals-title">
<div class="kit-section-head"><h2 id="kit-refusals-title" class="kit-section-title">What the gates refuse</h2><p>Three ways an agent-driven change goes wrong without anyone noticing, and the lock that stops each one.</p></div>
<ul class="kit-refusals">
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
<tr><td>A legacy .NET app</td><td>The <a href="migrate.md">.NET add-on</a></td></tr>
<tr><td>A new repo for these skills</td><td><code>/tagout:init</code></td></tr>
<tr><td>Something is already broken</td><td><code>debug-issue</code> fires on its own</td></tr>
</tbody>
</table>
</section>

<section class="kit-section" aria-labelledby="kit-dotnet-title">
<div class="kit-section-head"><h2 id="kit-dotnet-title" class="kit-section-title">For a legacy .NET app</h2><p markdown="span">The add-on cleared three apps from dead platforms in 18 minutes (Chords), about 30 minutes (Les Fleurs du Mal) and about 1 hour (Pokédex G), timed from the gate commits. The apps, the seven phases and the install line are on [the .NET add-on](migrate.md).</p></div>
</section>

<section class="kit-section" aria-labelledby="kit-siteindex-title">
<div class="kit-section-head"><h2 id="kit-siteindex-title" class="kit-section-title">The rest of the site</h2><p>The method in full, the decisions behind it, and one article per release.</p></div>
<ul class="kit-siteindex">
<li markdown="span">[The methodology](methodology.md)<span>The two loops in full, one page per skill, the machinery, and how the kit compares to GSD, SpecKit and BMAD.</span></li>
<li markdown="span">[.NET add-on](migrate.md)<span>The seven-phase migration pipeline, the four apps it cleared and the gate that routes C# through Roslyn.</span></li>
<li markdown="span">[Decisions](decisions.md)<span>Control-flow decisions have one program and one home.</span></li>
<li markdown="span">[Architectural Decision Records](adr/README.md)<span>The decisions that are hard to reverse, and the ones declined.</span></li>
<li markdown="span">[The roseline gate](roseline-gate.md)<span>Why every C# read and write goes through RoselineMCP.</span></li>
<li markdown="span">[The bundle gate](bundle-gate.md)<span>The opt-in drift gate for committed bundles.</span></li>
<li markdown="span">[Demo walkthrough](demo-walkthrough.md)<span>A real pipeline run on the bundled legacy fixture.</span></li>
<li markdown="span">[Journal](journal/index.md)<span>One article per release: why it happened, what got cut, what bit us.</span></li>
<li markdown="span">[Platforms](platforms.md)<span>What each host gets: skills, commands, MCP servers, gates, sub-agents.</span></li>
</ul>
</section>
