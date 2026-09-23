## HTML pages and Claude Artifacts

<important if="you are building an HTML page, report, or dashboard, or publishing one as a Claude Artifact">

- Build the page on the render kit in `~/.claude/shared/render-kit.md`: semantic HTML on Pico CSS, code in speed-highlight blocks, only the classes the kit names, and the kit's three markers, which `assemble.py` replaces with the kit's files.
- Publish to a Claude Artifact the copy that `python3 ~/.claude/shared/render-kit/inject-styles.py <page> -o <copy>` writes: Artifacts block external stylesheets, so the CSS has to travel inside the file.

</important>
