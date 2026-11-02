# Blinky iOS layout

The usage screen should look like a native settings list that happens to
show quotas. The references below are the ones people point at when a
screen feels generic: a few real Apple and ChatGPT layouts, then the same
grid in SwiftUI. No extra stripes, rails, or a second accent color.

## References

- **Apple Screen Time, app row.** The name sits on the left. The duration
  sits on the same baseline on the right. A single bar runs under that
  pair, full width. The row is short. There is no giant number in the
  empty half of the card.
- **Apple Fitness summary.** A card has one title line and a value. The
  secondary fact (time, unit) is a caption under the title, not a second
  headline.
- **iOS Battery settings and the Battery widget.** "85%" is a trailing
  value, semibold, on the same line as the name. The row is one horizontal
  pair. Nothing decorative sits in the leading margin.
- **Apple Weather card.** Padding is even (16pt). Corners are continuous.
  One value, one caption, then the content. The card background is the
  surface. The type does the hierarchy.
- **ChatGPT / Codex usage widget.** Several limits stack in one card.
  Each limit is name, trailing percent, then a full-width bar. The footer
  (reset, updated) is smaller type in the same leading column.

People on X keep coming back to the same method: write down three to five
screens you already trust, extract the grid, then build it with stock
SwiftUI. Appllama's notes on design research and native build standards
are the same idea. Custom ornament is what makes the screen look generated.

## The grid

Spacing is 4 and 8. 16 is two steps and is the card padding. Do not invent
a third gap.

| Role | Style | Use |
| --- | --- | --- |
| Title | Headline, semibold | Account name only |
| Name | Subheadline, regular | Limit name, settings row |
| Value | Subheadline, semibold, rounded, monospaced digits | Percent, trailing |
| Secondary | Caption, secondary color | Reset, plan, forecast |
| Caption | Caption 2, tertiary | Updated |

A row uses at most two weights: regular for the name, semibold for the
value. The caption under the name stays regular.

The value column is trailing and shares the name's baseline. The bar is
the next line and is always the full width of the text column. Card
padding is 16. Glass corners are 16 continuous. Classic uses the system
grouped list corner.

Row height is the text line, an optional 4pt caption, then the bar.
About 44pt when there is no caption, about 64pt with a reset line.

Settings and Classic usage are lists. Screen Time and Liquid Glass are
the same rows on a different surface: a cool gray page, or a glass plate
on a tinted field. The surface changes. The row does not.

One accent: the remaining-allowance color, on the percent and the bar
only. No leading stripe, no colored icon tile, no second hue for
decoration.

## Where it shows up

- **Quota row.** Name left, percent right, reset caption under the name,
  bar full width.
- **Account header.** 28pt icon, name, plan. Gear on the trailing edge.
  8pt between the header and the first quota row.
- **Footer.** Banked reset, forecast, and updated are one block of
  secondary text, 4pt apart, same leading edge as the quota names.
- **Settings.** Stock labels and grouped rows. Style is the page surface,
  not a custom icon.
