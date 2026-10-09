# Craft reference

Adapted from [variate](https://github.com/Nutlope/variate) (MIT).

## Steers

Each steer bends the designs and keeps the brand:

- **calmer**: more restraint, softer contrast, fewer elements
- **bolder**: bigger type, stronger presence, higher contrast
- **airier**: more whitespace, lighter density
- **denser**: tighter spacing, more information in view
- **playful**: unexpected details, tasteful motion

## Content

Every word belongs to the real product: lift its copy, or write specific plausible content. Real buttons, real labels, real sentences. Proof stays out of mocks entirely: logo walls, testimonials, customer counts, revenue. Layout gets redrawn later; an invented number ships. Name each button, link, and status by its job; `~/.claude/shared/interface-copy.md` has the grammar.

## Structure

Structure carries information. A border, a divider, a number, a label above a block each say something about the content. Number items only when they form a real sequence, such as steps or a timeline.

## Type

Make the type itself part of the composition, not a neutral carrier. Carry emphasis with size, weight, and space.

Keep lines under 80 characters. A serif body may run slightly longer and takes slightly more line-height than a sans.

Two treatments read as generated, so use them only when the brief asks: one accented word inside a headline, and all-caps labels.

## Motion

The first question is whether to animate at all. Something used many times a day stays still; speed is its feature. When something moves: ease out on the way in, stay under a third of a second, move only `transform` and `opacity`, and switch the motion off under `prefers-reduced-motion`. When a round is about motion, say so in the design's `angle`; clicking the live chip in the picker replays it.
