# Interface rubric

Wisp's best screens are the CPU and Memory dropdowns and the CPU and Memory pages.
This rubric writes down what they do, so a new screen can be scored before release
and an old one compared with them.

## Capture

`scripts/ui-audit.sh` draws every window page at each size in light and dark, then
every menu bar dropdown and the dashboard. Score from those pictures, at 1440x900,
in both appearances. A page caught while it loads is scored again once it has loaded,
and its loading state is scored on its own under **States**.

## Criteria

There are eight criteria. Each scores 0 to 3. A criterion that cannot apply, such as a chart on a
settings form, is marked n/a and left out. The score is the points over the points
possible, out of 10.

| | Criterion | 3 means |
| --- | --- | --- |
| **H** | Headline | One figure, with its unit and a state pill when the state matters, answers the screen's question before anything is read. A caption says what the figure means or where it is going. |
| **V** | Graphic | At least one graphic shows change over time or how a whole splits into parts, such as a filled chart, the core map or the memory grid. Bars alone score 1. |
| **R** | Rows | Lists use one grammar: label, bar, bold figure and quiet detail. Columns line up down the card and across cards side by side. Figures use tabular digits. |
| **S** | Structure | Built from the shared parts, such as tinted card labels, glyph tiles and the plate under a dropdown's cards, with one row pitch. Cards fit what they hold, with no void inside a card and no card left to stretch. |
| **C** | Colour | The screen's tint on labels and charts. Amber and red only for state, and never the only sign of it. Light and dark both read. |
| **E** | States | Loading, empty, signed out and no permission each say what is happening and what to do, in the space the content will take. No blank card. |
| **D** | Detail | Hover shows more (a clock time, a pace, an earlier reading). Long text ends in an ellipsis with the whole of it on hover. No text overlaps other text or runs past its card's edge. Footers give a hint and a way on. |
| **F** | Family | Placed beside its siblings, it reads as one design. A dropdown is judged beside the CPU dropdown and a page beside the CPU page. The same part (a meter, a pill, a card header, a placeholder row) is drawn the same way wherever it appears. A 1 is a screen that works but looks a generation older than its siblings. |

A screen is ready for a release at 9 or above, and with a 2 or more under Family:
a screen that scores well on its own but looks older than its siblings is not
ready. Below 8, it gets a ticket before anything new is added to it.

To score Family, put the screen's capture next to its sibling's (for a dropdown,
`dropdowns-dark/cpu.png`; for a page, `dark-1440x900/cpu.png`) and look at them
together, not one after the other.

## Anchors

These are what a 3 looks like.

- **H**: the CPU page. `95 %`, a Strained pill, then "10 performance and 4 efficiency
  cores".
- **V**: the CPU page's core map, or the Memory page's grid by kind.
- **R**: the CPU dropdown's Right now card: `Apps ▬▬▬ 15% · User`.
- **S**: any soft dropdown: a plate titled This Mac holding the chart card, the Right
  now card and the Using the most card.
- **D**: AI usage rows, which show the reset's clock time or the pace while hovered.

## Scores

Scored again on 26 November 2026, after the pass that raised every screen to 9 or
more and the dashboard's move to the dropdowns' design, from dark and light captures
at 1440x900 with the layout check at 900x620. The Network and Disk dropdowns are scored after the fix
for the header text that ran under the value pill.

| Screen | H | V | R | S | C | E | D | F | Score |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CPU page | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Memory page | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Overview | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Network page | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Battery page | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| CPU dropdown | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Memory dropdown | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Battery dropdown | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| GPU dropdown | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Disk dropdown | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| AI usage dropdown | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Projects | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Login & Background | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Clean Up | 3 | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 9.6 |
| Storage | 3 | 3 | 3 | 3 | 3 | 2 | 3 | 3 | 9.6 |
| Dashboard | 2 | 3 | 3 | 3 | 3 | 3 | 3 | 3 | 9.6 |
| Bluetooth, before access | 3 | 2 | n/a | 3 | 3 | 3 | 3 | 3 | 9.5 |
| Settings | n/a | n/a | 3 | 3 | 3 | 2 | 3 | 3 | 9.4 |
| Temperature dropdown | 3 | 3 | 3 | 3 | 2 | 2 | 3 | 3 | 9.2 |
| Network dropdown | 3 | 3 | 2 | 3 | 3 | 2 | 3 | 3 | 9.2 |
| Sensors page | 3 | 3 | 3 | 3 | 3 | 2 | 2 | 3 | 9.2 |
| GPU page | 3 | 3 | 3 | 3 | 3 | 2 | 2 | 3 | 9.2 |
| Coding Agents | 3 | 2 | 3 | 3 | 3 | 2 | 3 | 3 | 9.2 |
| Apps page | 3 | 2 | 3 | 3 | 3 | 2 | 3 | 3 | 9.2 |
| App drawer | 3 | 2 | 3 | 3 | 3 | 2 | 3 | 3 | 9.2 |
| Containers | 3 | 2 | 3 | 3 | 3 | 2 | 3 | 3 | 9.2 |
| Neural Engine | 3 | 2 | 3 | 3 | 3 | 3 | 2 | 3 | 9.2 |
| Sound | 3 | 2 | 3 | 3 | 3 | 2 | 3 | 3 | 9.2 |

A 2 under Graphic on the Containers, Sound, Neural Engine, App drawer and Coding
Agents rows is for charts that start empty or flat: they fill in as Wisp keeps the
page open or records the day.
