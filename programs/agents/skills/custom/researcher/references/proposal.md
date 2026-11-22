# Proposal mode

Your prompt names this file and one section of it, with a plan path, the
research notes paths and `notes`, a directory under `/tmp`. It replaces the
researcher skill's Process, Notes and Hand-back. Its rules on bounded reads,
labels and data still hold, and so does its Budget for your Fuel.

## Rules

- You report findings; you never edit the plan. The engineer decides each row.
- Keep the plan's goals and intent. Not naive: a change still meets every
  goal and every decision the user made. A design issue's settled Decisions
  stand as written: a finding never changes one.
- Every claim about the repo has a `path:line`; every outside claim a URL.

## Simplify

Find where the plan could be simpler and still equivalent: fewer moving
parts, an existing helper or tool, a step or file to delete. One row per
place. Standards are the Standards pass's job, not yours. Nothing simpler:
say so and why, which leaves the plan as it is.

## Standards

Search reputable standards libraries online for each concern of the plan,
and give the engineer everything to verify and decide.

1. Classify each concern: data format, wire protocol, identifier or name,
   versioning, config or env, CLI, file locations, time or units, security
   control, observability, process or state machine.
2. Search the bodies for that class first, then the general web:

| Source | Search |
|---|---|
| IETF (RFC, BCP) | `datatracker.ietf.org/api/v1/doc/document/?title__icontains=<q>&format=json`; text at `rfc-editor.org/rfc/rfc<n>.txt` |
| IANA registries | `iana.org/protocols` (media types, URI schemes, ports, headers) |
| W3C, WHATWG | `w3.org/TR/`, `spec.whatwg.org` |
| De-facto spec sites | OpenTelemetry semconv, OpenAPI, JSON Schema, CloudEvents, semver.org, CommonMark, clig.dev, 12factor |
| POSIX, XDG | `pubs.opengroup.org/onlinepubs/9799919799/`, `specifications.freedesktop.org` |
| OWASP | ASVS on GitHub, `cheatsheetseries.owasp.org` |
| Ecma, Unicode, OASIS | `ecma-international.org`, `unicode.org/reports/`, `docs.oasis-open.org` |
| ISO, IEC, IEEE | iso.org blocks bots: read the IEC webstore preview, a sample PDF from `standards.iteh.ai` or Wikipedia; IEEE's record page `standards.ieee.org/ieee/<n>/<id>/` gives abstract and status |

3. Keep a match only when it solves the same problem at the same layer. Read
   its Scope section and its status: active, or obsoleted by what.

Per match, give the engineer everything to verify it: the id, the section,
the URL, what it prescribes and the change to the plan. No standard applies:
say plainly "no standard applies", which leaves the plan as it is.

## Output

Write the table your task gives to `<notes>/refine-<pass>.md`, `<pass>` the
section you ran (`simplify`, `standards`). Hand back its path and the table.
