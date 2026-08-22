---
version: alpha
theme: dark
name: Airlock
description: >-
  The design system for Airlock, a self-hosted workspace for a single dev
  server. Eleven colours in four groups: a surface ladder, a text ladder, one
  blue primary, and two reserved state colours. Hierarchy comes from the
  ladders, never from hue. The dark theme is canonical and lives in
  DESIGN.md holds the light override — this file is the canonical theme.
colors:
  canvas: "#0a0f1e"
  surface1: "#141b2e"
  surface2: "#1d2740"
  hairline: "#2b3752"
  ink: "#f5f5f7"
  body: "#c3cbd9"
  mute: "#8b93a5"
  primary: "#2997ff"
  onPrimary: "#0a0f1e"
  warning: "#ffb340"
  danger: "#ff6961"
typography:
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Noto Sans KR, Apple SD Gothic Neo, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "-0.022em"
  lead:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Noto Sans KR, Apple SD Gothic Neo, sans-serif"
    fontSize: "20px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "-0.022em"
  small:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Noto Sans KR, Apple SD Gothic Neo, sans-serif"
    fontSize: "15px"
    fontWeight: 500
    lineHeight: 1.5
    letterSpacing: "-0.022em"
  caption:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Noto Sans KR, Apple SD Gothic Neo, sans-serif"
    fontSize: "13px"
    fontWeight: 500
    lineHeight: 1.5
    letterSpacing: "0.04em"
  h1:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Noto Sans KR, Apple SD Gothic Neo, sans-serif"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.5
    letterSpacing: "-0.022em"
  h2:
    fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Noto Sans KR, Apple SD Gothic Neo, sans-serif"
    fontSize: "21px"
    fontWeight: 600
    lineHeight: 1.5
    letterSpacing: "-0.022em"
  mono:
    fontFamily: "SF Mono, SFMono-Regular, JetBrains Mono, Cascadia Code, Consolas, D2Coding, monospace"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: "0em"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "24px"
  section: "32px"
  page: "48px"
rounded:
  sm: "8px"
  md: "12px"
  lg: "14px"
  tile: "15px"
  pill: "9999px"
components:
  page:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    padding: "{spacing.xxl}"
  card:
    backgroundColor: "{colors.surface1}"
    textColor: "{colors.ink}"
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
  prose:
    textColor: "{colors.body}"
    typography: "{typography.body}"
  buttonPrimary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.onPrimary}"
    typography: "{typography.small}"
    rounded: "{rounded.pill}"
    padding: "{spacing.md}"
    height: "36px"
  buttonQuiet:
    backgroundColor: "{colors.surface1}"
    textColor: "{colors.body}"
    typography: "{typography.small}"
    rounded: "{rounded.pill}"
    padding: "{spacing.md}"
    height: "36px"
  input:
    backgroundColor: "{colors.surface1}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    height: "36px"
  appTile:
    backgroundColor: "{colors.surface2}"
    textColor: "{colors.primary}"
    rounded: "{rounded.tile}"
    size: "60px"
  sectionLabel:
    textColor: "{colors.mute}"
    typography: "{typography.caption}"
  badge:
    backgroundColor: "{colors.surface2}"
    textColor: "{colors.mute}"
    typography: "{typography.caption}"
    rounded: "{rounded.pill}"
    padding: "{spacing.sm}"
  divider:
    backgroundColor: "{colors.hairline}"
    height: "1px"
  statusWarning:
    backgroundColor: "{colors.surface1}"
    textColor: "{colors.warning}"
    typography: "{typography.small}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
  statusDanger:
    backgroundColor: "{colors.surface1}"
    textColor: "{colors.danger}"
    typography: "{typography.small}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
---

## Overview

Airlock is one entry point to one machine. The interface is a launcher you open
from a phone as often as from a desktop, so the system optimises for **calm at
a glance**: a quiet surface, one colour that means "this is interactive", and
enough contrast that it survives a bright window and a dark room equally.

Four rules decide every question this file does not answer explicitly.

1. **One primary colour.** Information, emphasis, links, focus and normal state
   are all `{colors.primary}`.
2. **Hierarchy comes from the ladders, not from hue.** If something should
   recede, move it down the text ladder — `{colors.ink}` to `{colors.body}` to
   `{colors.mute}`. Do not colour it instead.
3. **Colour carries state and interaction. Never decoration.**
4. **Components read tokens.** No raw hex outside the token file.

**This is the canonical theme.** These are the values that ship by default;
`DESIGN.md` is the light override. Structure, typography, spacing and radii are
identical between the two, and only the palette changes. The split exists
because the format has no way to express two themes in one file.

The value source of truth is `hub/assets/airlock-tokens.css`. This file is a
derived view of it for agents; if the two disagree, the CSS is right.

The DESIGN.md convention puts this file at the repository root, where agents
look for it by default. It lives here instead because this repository pins its
root layout: a new top-level path fails the cutline guard, which only accepts
prefixes that existed at the pinned baseline. Point tooling at
`docs/design/DESIGN.md`.

## Colors

Eleven colours, in four groups. The grouping is the point — a palette that
reads as four things is easier to hold than one that reads as eleven, and the
naming is what does that work.

**Surface ladder** — one material at four depths.

| Token | Value | What it is for |
|---|---|---|
| `canvas` | `#0a0f1e` | The page. |
| `surface1` | `#141b2e` | Cards, panels, raised rows. |
| `surface2` | `#1d2740` | Nested surface, hover fill, and the app tile. |
| `hairline` | `#2b3752` | Borders. Never a text colour. |

**Text ladder** — three weights, which is where hierarchy actually comes from.

| Token | Value | What it is for |
|---|---|---|
| `ink` | `#f5f5f7` | Primary text. |
| `body` | `#c3cbd9` | Secondary text and long-form reading. |
| `mute` | `#8b93a5` | Labels, timestamps, disabled. |

**Primary** — the only strong colour on a screen.

| Token | Value | What it is for |
|---|---|---|
| `primary` | `#2997ff` | Links, focus, primary action, emphasis. |
| `onPrimary` | `#0a0f1e` | Text placed on top of the primary. |

**State** — reserved.

| Token | Value | What it is for |
|---|---|---|
| `warning` | `#ffb340` | Something needs attention. |
| `danger` | `#ff6961` | Something is broken or destructive. |

**There is no success colour.** "Working" is the normal case, and the normal
case is unremarkable. Colouring it green makes every healthy row shout, and a
reader who learns that a colour sometimes means nothing stops reading colour at
all. For comparison, linear.app ships exactly one semantic colour and warp
ships none.

**The launcher tile is the one exception to rule 3, and it is deliberate.**
Tile colour belongs to the app, not to this palette. The system owns the
geometry — the squircle, the 60px, the shadow, the glass edge — and the app
owns its hue, which is how iOS works and why you can find an app on a home
screen before you have read a single label.

Those hues are therefore **not tokens** and must not be folded into
`colors`. They are data about each tool, and pulling them in here would make
this document claim authorship of a decision it does not own. `{colors.surface2}`
in `appTile` above is the fallback for an app that declares no colour of its
own. Today the value is keyed off the app's category; per-app colour in
`airlock-app.toml` is the next step.

Everything outside the tile still follows rule 3.

Every foreground/background pair is verified against WCAG AA by
`install/test-design-tokens.py`, which fails rather than warns. All three text
levels are checked against all three surfaces, because the pair that failed
during the first draft — a secondary grey inside a badge, at 4.39:1 — passed on
the page and on a card and was caught only by the third surface.

## Typography

One family, the system stack, so text renders natively on macOS, Windows and
Android without shipping a webfont. Korean falls back to Apple SD Gothic Neo
and Noto Sans KR, which matters because operator-facing text is often Korean
while product text is English, sometimes in the same line.

Body is **17px at 1.5 with -0.022em tracking**. Sizes are literal, not a
computed scale — a scale would imply the steps were derived, and they were
chosen. `caption` is the only role with positive tracking, because it is the
only role set in uppercase.

## Layout

Spacing is a 4px base. Content sits in a single column capped at **880px** and
centred; the launcher grid inside it is `auto-fill` at a 92px minimum column,
so it reflows from a phone to a desktop without breakpoints.

Use `{spacing.xxl}` for page padding, `{spacing.lg}` inside cards,
`{spacing.section}` between sections, and `{spacing.sm}` between an icon and
its label. Anything smaller than `{spacing.xs}` is optical adjustment and
belongs in the component, not in the scale.

## Elevation & Depth

Elevation is shadow plus a hairline, never colour. Two levels:

- **Resting** — `0 3px 10px -2px rgba(0,0,0,.55), 0 0 0 1px rgba(255,255,255,.06)`
- **Hover** — `0 10px 20px -5px rgba(0,0,0,.60), 0 0 0 1px rgba(255,255,255,.08)`,
  paired with a 3px lift over 160ms on `cubic-bezier(.2,.8,.2,1)`.

The 1px rim of white is not ornament. A shadow alone does not separate two dark
surfaces, so the rim is what makes elevation readable at all in this theme.

Borders and shadows cannot be expressed in this format's component vocabulary,
so they live here in prose rather than in the front matter. That is a limit of
the format, not an oversight — the same reason `divider` above is a 1px block
of `{colors.hairline}` rather than a border property.

## Shapes

Four radius steps and a pill. `{rounded.tile}` at 15px is the launcher's iOS
squircle radius and is kept as its own step rather than folded into the scale,
because at 60px the difference from 14px or 16px is visible.

Pills are for things read as a single token — a status chip, a filter, a small
button. Anything containing more than one line of text takes `{rounded.md}` or
`{rounded.lg}`.

The brand mark is a circle in deep-space navy with a blue rim. It is the only
true circle in the system.

## Components

The front matter above is the contract. Three notes it cannot express:

- **`buttonQuiet`** carries a 1px `{colors.hairline}` border; `buttonPrimary`
  has no border at all.
- **Focus** is a 3px ring of the primary at 30% opacity, on every interactive
  element, in both themes. It is never removed, only restyled.
- **`appTile`** is 60px square with a glass edge: a bright radial highlight at
  the top-left corner and a softer one at the bottom-right, both white and
  under 32% opacity.

## Do's and Don'ts

**Do**

- Move down the text ladder when something should recede. That is what it is
  for, and it costs no colour.
- Reach for `{colors.primary}` when something is interactive.
- Let each app's tile carry its own colour, and let the glyph carry its shape.
- Keep dark as the default and treat light as the override — including when
  adding a token, which goes into both themes in the same commit.
- Run `python3 install/test-design-tokens.py` after touching any colour. It
  computes contrast rather than trusting the eye.

**Don't**

- Don't add a colour to signal hierarchy. Use `{colors.body}` or
  `{colors.mute}`.
- Don't add a second strong colour to a screen. If two things both need to
  shout, one of them does not.
- Don't use `{colors.warning}` or `{colors.danger}` for emphasis. They mean
  what they say, and a reader who learns they sometimes mean nothing will stop
  reading them.
- Don't add a success colour back. See the Colors section.
- Don't extend the airlock metaphor into UI vocabulary. There are no hatches,
  docks, stations or berths. The name carries the metaphor; the interface is
  literal.
- Don't add a token to one theme only. It inherits the other theme's value and
  produces exactly one illegible element, in the theme nobody tested.
- Don't hand-edit this file to change a value. Change
  `hub/assets/airlock-tokens.css` and regenerate.
