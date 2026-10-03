# pdf-to-markdown

An agent workflow for faithful PDF transcription. It combines native extraction, optional local OCR, visual reconstruction and a separate verification pass. The bundled helper prepares evidence; a vision-capable agent writes and reviews the Markdown.

## Runtime

The helper uses Python 3.10+ and uv with pinned `pdfplumber`. Rendering uses pdfplumber's PDF renderer. Tesseract and the requested language packs are required only with `--ocr`. OCR runs locally. Images passed to a hosted vision agent follow that agent's normal data path; this is not a claim that model inference runs locally.

From the skill directory:

```sh
uv run --script scripts/prepare_pages.py book.pdf --info
uv run --script scripts/prepare_pages.py book.pdf --pages 1-4,20 --out /path/to/new-batch
uv run --script scripts/prepare_pages.py book.pdf --pages 34 --out /path/to/new-ocr-batch --ocr --lang eng
uv run --script scripts/prepare_pages.py book.pdf --pages 16 --out /path/to/new-ukr-batch --ocr --lang ukr --tessdata /path/to/language-packs
```

Page selections are physical, one-based, inclusive. Output directories must be new to preserve prior evidence. The helper saves an image, native text, native words with PDF-point coordinates, and optional OCR text/TSV with pixel coordinates for each page. `manifest.json` records source hash, page dimensions, settings, per-page statuses, errors and outputs. Render scale is `dpi / 72`; use this when comparing the two coordinate systems.

Progress and final counts go to stderr. `--info` prints compact JSON. Exit 0 means the selected preparation completed, exit 1 means a runtime/preparation failure, exit 2 means invalid arguments. Per-page failures are recorded and remaining pages still run. An existing output directory is never reused. A manifest with errors is partial evidence, not a successful batch.

The helper intentionally does not guess final headings. The seven-page pilot found that font-size/OCR-height heuristics missed real titles and promoted stat fields. Visual reconstruction performed much better; full-book hierarchy and continuity still need their own pass. OCR helped corrupted English font mappings but introduced errors into sound Ukrainian text, so it is selective rather than mandatory.

## Final artifacts

The workflow writes a new `*.extracted.md`, its `.toc`, and an evidence report. Existing PDF and Markdown files are preserved. Partial-page outputs say which pages they contain. Raw OCR, page images and correction logs remain in the work directory. `document-map` indexes the completed Markdown independently of conversion.

## Reference material

- [pdf-extraction](https://raw.githubusercontent.com/claude-office-skills/skills/refs/heads/main/pdf-extraction/SKILL.md): native text, font positions, tables and rendering with pdfplumber.
- [pdf-ocr](https://raw.githubusercontent.com/claude-office-skills/skills/refs/heads/main/pdf-ocr/SKILL.md): OCR preparation and reporting ideas. Its general quality percentages are not evidence for a particular document.

## Repository verification

`python3 -m unittest tests.test_pdf_to_markdown` checks the real preparation helper on a small PDF, including physical-page selection, evidence, preservation and partial failure. Model reconstruction quality is evaluated against source images, not by grepping skill prose. See `evals/evals.json` for portable acceptance tasks; supply local sample PDFs when running them.
