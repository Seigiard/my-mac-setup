# Capturing evidence

Read from make-pr step 3. The outcome is a set of captioned frames, each with a URL or a listed local path, feeding the Visuals line.

## Decide the surface

The diff has a visible surface when it touches routes, components, stories, styles, or CLI output. Everything else is behavioural: the proof is the test output or log of the change running, captured as text. Text stays text: the closing lines of the run go into the body's Before and After lines, never rendered into an image.

## Capture a visible surface

1. Start the app the way the repository documents. When it cannot start in this session, use the affected Storybook stories; when those are absent too, the change has no frame this session: keep the run's output as text and say which fallback applied.
2. Drive the branch with the Playwright tools (`browser_navigate`, `browser_take_screenshot`): one PNG per state the reviewer must see, saved as `/tmp/<slug>/evidence/<nn>-<caption>.png`. The caption in the file name becomes the alt text.
3. A "before" frame comes from the base only when a checkout of it is already running; otherwise the Before line of the body says it in words.

## Host the frames

Take the first route that applies.

1. **The publisher the repository documents.** When step 1 found an image-upload or demo-page command, that command wins. Use it and keep the URLs beside the captions.
2. **`gh --attach`.** Write each frame into the body as a Markdown reference to the file's own path, `![caption](/tmp/<slug>/evidence/<nn>-<caption>.png)`, and pass that same path to `--attach` on the publishing command. `gh` rewrites the reference to the uploaded URL and keeps the caption written there as the alt text. Its constraints are the `gh` skill's; the one that redirects this step is `WRITE` on the repository the PR opens against, so a fork PR into an upstream the token cannot write lands on route 3. Uploading to a repository the token can write (`gh issue comment --attach` on the fork) turns that case back into route 1.
3. **Local paths.** Keep the references, list the paths in the report, and say which route failed and why.
