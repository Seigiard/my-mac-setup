## HTML pages and Claude Artifacts

<important if="you are building an HTML page, report, or dashboard, or publishing one as a Claude Artifact">

- Build the page on the render kit in `~/.claude/shared/render-kit.md`: bare semantic HTML styled by the kit's own base layer, code as `<pre><code class="language-x">`, no classes beyond `language-x` and `mermaid`, and the kit's three markers, which `assemble.py` replaces with the kit's files.
- Publish the assembled page to a Claude Artifact as it is: the kit loads no external stylesheet, which Artifacts would block.

</important>
