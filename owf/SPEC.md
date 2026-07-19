# OWF — Open Workout Format

**Version 0.1 (draft).** An open, plain-text, append-only file format for sports
sensor data. This core spec is intentionally one page and is frozen at one page:
anything that doesn't fit here belongs in an extension.

The key words MUST, SHOULD, and MAY are to be interpreted as in RFC 2119.

## File

- A file is UTF-8 [JSON Lines](https://jsonlines.org): one JSON object per line,
  each line terminated by `\n`. Recommended extension: `.owf`.
- The **first line is the header**. Every following line is a **record**.
- Files are append-only. There is no footer, checksum, or closing element.
  A file whose last line is truncated (crash mid-write) is valid; readers MUST
  discard an unparseable final line and keep everything before it.

## Header

```json
{"owf":"0.1","start":"2026-07-19T08:30:12Z","sport":"cycling","channels":{"hr":"bpm","pwr":"W","cad":"rpm","lat":"deg","lon":"deg"},"source":{"app":"Orbeat","device":"Fitbit Charge 6"}}
```

| Field      | Required | Meaning |
|------------|----------|---------|
| `owf`      | yes      | Format version, currently `"0.1"`. |
| `start`    | yes      | Absolute start time, RFC 3339 with timezone (UTC recommended). |
| `channels` | yes      | Map of channel name → unit string, for every channel the file uses. |
| `sport`    | no       | Free-form lowercase string (`"cycling"`, `"running"`, …). |
| `source`   | no       | Object describing the recorder (`app`, `device`, free-form). |

Channel names are lowercase ASCII (`[a-z][a-z0-9_]*`). Units are free-form
strings; use the obvious SI or domain unit (`bpm`, `W`, `rpm`, `deg`, `m`,
`km/h`, `mmol/L`). GPS is not special: `lat`/`lon` are channels like any other.

## Records

Every record has `t`: seconds since `start`, as a JSON number, ≥ 0. Fractional
values are legal. Writers SHOULD emit non-decreasing `t`; readers MUST tolerate
minor disorder (sort by `t`).

**Samples** carry one or more channel readings:

```json
{"t":0,"hr":121,"pwr":250,"cad":88}
{"t":1.02,"hr":122}
```

- A channel absent from a sample means **no reading** — never zero. Dropouts
  stay visible as gaps.
- Values are JSON numbers in the header-declared unit.

**Events** carry `ev` (a string) instead of channel values:

```json
{"t":63.5,"ev":"lap"}
```

Core event names: `lap`, `pause`, `resume`, `marker`. Readers MUST preserve
unknown event names.

## What is deliberately absent

- **No stored summaries.** Averages, maxima, calories, and totals are derived
  data — recomputable from samples, therefore cache, therefore not in the file.
- **No finalize step.** The file on disk during recording *is* the file.

## Extensions

Unknown keys prefixed `x-` MAY appear in the header or in any record. Readers
MUST ignore (and SHOULD preserve) keys they don't understand. Everything beyond
this page — planned-workout structures, per-channel metadata, summaries —
lives in `x-` extensions, never in the core.

## Multiple recorders (non-normative)

Independent devices record the same session as independent files — no runtime
coordination. To merge: absolute time of a record is `start + t`; align files on
absolute time, collapse readings of the same channel within ±0.5 s, keep
genuinely different values (they are different sensors' facts). Original
per-device files remain the truth; a merged file is cache.
