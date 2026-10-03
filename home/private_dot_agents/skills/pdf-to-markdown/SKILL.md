---
name: pdf-to-markdown
description: Convert PDFs into source-linked Markdown using native text, local OCR, and visual reconstruction. Use when asked to convert a PDF, recover unreadable extracted text, or create structured Markdown for a PDF without bookmarks before indexing it with document-map.
---

# PDF to Markdown

Produce a faithful transcription with useful headings, not a summary. Native text supplies a draft; page images decide what the source says. OCR confidence and a fresh TOC do not establish transcription quality.

## 1. Scope and inspect

Locate the input PDF and any existing Markdown. Preserve both. Choose a work directory outside the source tree and record the requested physical pages, or the whole-book scope. A missing PDF outline alone is not a request to convert an entire book.

Use `scripts/prepare_pages.py` through `uv run --script` to get PDF metadata (`--info`), then prepare a small sample with `--pages` and `--out`. See [README.md](README.md) for arguments and runtime requirements. Sample the beginning, middle, end, and distinct layouts: columns, tables, ornate type, or scanned pages. Preparation is complete when images, native text, coordinates, and their manifest exist for every selected page or a specific failure is recorded.

Compare native text to the images. Missing visual labels, private-use characters, printable letter substitutions, or interleaved columns justify visual reconstruction and, where useful, OCR. Keep sound native text: OCR can corrupt valid spelling, numbers, and dice notation. Sparse native text may mean a blank page, illustration, outlined lettering, or a scan; inspect the image to distinguish them.

## 2. Prepare evidence

Run the helper for explicit page batches. Each output directory must be new. Start with 4–8 pages per batch; reduce that for dense pages. The helper renders at 300 dpi and saves raw native words with positions. Add `--ocr --lang eng` or the installed source language for problematic pages. For small text, try a 600 dpi crop or page and compare it to the original pass. Language packs can be kept in a separate temporary directory with `--tessdata`.

The helper performs local extraction and optional Tesseract OCR. It does not create finished Markdown or infer a trusted hierarchy. Use its images with a vision-capable agent. If image input or a needed OCR language is unavailable, record that limitation; text-only processing is not a completed visual reconstruction.

## 3. Reconstruct and delegate

Read [references/reconstruction.md](references/reconstruction.md) before dispatching or transcribing. It defines the output and verification contract.

For a whole book or several batches, delegate reconstruction to separate workers. Each worker receives that contract, its page images and raw evidence, physical page numbers, output paths, and the current shared style map. Keep known acceptance answers out of the reconstruction prompt. Give a following batch one preceding page for context, but assign every output page to exactly one worker.

Workers write page-addressed Markdown and correction/uncertainty logs to files. They return only page coverage, status, uncertainty counts, style decisions that need coordination, and artifact paths. The main agent coordinates those small results instead of collecting books, full OCR, or all TOCs in context. If delegation is unavailable, process one batch at a time with the same on-disk artifacts and disclose the context limit.

Start with the sample. Inspect its output before scheduling the remaining book. Once the sample works, keep the layout conventions in a shared style map, rather than independently renumbering headings in every batch. Finish reconstruction only when each assigned page has an output or an explicit unresolved status.

## 4. Assemble and verify

Assemble in physical page order. Reconcile continued paragraphs, lists, tables, and repeated headings across every batch boundary. Use whole-book evidence for heading levels; page-local font sizes alone cannot establish chapter nesting. Keep physical page comments in the merged Markdown and retain the work manifest that maps pages to their evidence.

Have a separate worker compare the reconstruction with the original images, including all numeric expressions and changes made to OCR/native text. Use the verification section of the reconstruction contract. Keep this worker's findings separate from the author's correction log. Fix confirmed defects and recheck affected pages and their boundaries. A single-agent fallback must be reported as self-checked. Finish with an explicit verification scope and remaining uncertainties, rather than a blanket accuracy claim.

## 5. Publish and index

Save accepted output beside the source as `<PDF stem>.extracted.md`, choosing a new numbered name if that path or its `.toc` already exists. Keep partial work in the work directory. If only selected pages were requested, use `<PDF stem>.pages-<selection>.extracted.md` and list those pages in metadata so it cannot be mistaken for a whole-book conversion. Never overwrite an existing human-authored Markdown as a side effect of conversion.

Include provenance and review status from the reconstruction contract. Invoke [document-map](../document-map/SKILL.md) on the final Markdown, then run `--check`. Its TOC addresses Markdown lines, not original PDF pages; page comments provide the link back to the PDF. Run indexing after all reconstruction and assembly edits.

Return the Markdown, TOC and report paths, processed/requested page counts, verification scope, and unresolved limitations. Distinguish conversion completion, visual review, and index freshness. Keep raw evidence and correction logs available for follow-up.
