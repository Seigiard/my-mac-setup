# Capturing evidence

Read from make-pr step 3. The outcome is a set of captioned frames, each with a URL or a listed local path, feeding the Visuals line and the explanation page.

## Decide the surface

The diff has a visible surface when it touches routes, components, stories, styles, or CLI output. Everything else is behavioural: the proof is the test output or log of the change running, captured as text. Text stays text: the closing lines of the run go into the body's Before and After lines and into the explanation page as a code block, never rendered into an image.

## Capture a visible surface

1. Start the app the way the repository documents. When it cannot start in this session, use the affected Storybook stories; when those are absent too, the change has no frame this session: keep the run's output as text and say which fallback applied.
2. Drive the branch with the Playwright tools (`browser_navigate`, `browser_take_screenshot`): one PNG per state the reviewer must see, saved as `/tmp/<slug>/evidence/<nn>-<caption>.png`. The caption in the file name becomes the alt text.
3. A "before" frame comes from the base only when a checkout of it is already running; otherwise the Before line of the body says it in words.

## Host the frames

GitHub has no CLI upload for PR images, so a URL can only come from a publisher the repository documents (an image upload command, a demo-page command). Use it and keep the URLs beside the captions.

With no documented publisher, keep the local paths, list them in the report, and write each Visuals entry as `![caption](attach: <path>)` for the user to drag into the PR.
