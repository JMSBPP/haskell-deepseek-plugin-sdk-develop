# Architecture Decision Records

This directory holds Architecture Decision Records in [MADR 4.0.0](https://adr.github.io/madr/)
format. Each record captures one decision, the options weighed, and the evidence
that confirms it.

## Conventions

- Files are named `NNNN-kebab-title.md`, where `NNNN` is a zero-padded
  sequential number assigned when the record is written.
- Front matter uses the MADR 4.0.0 key names: `status`, `date`,
  `decision-makers`, `consulted`, `informed`.
- An accepted ADR is never edited except to change its `status`. Reversing a
  decision means writing a new ADR that supersedes the old one and marking the
  old one `superseded by NNNN`.

## Records

| Number | Title | Status |
| ------ | ----- | ------ |
| [0001](0001-harness-e2e-tiering.md) | End-to-end validation tier accepted by deepseek-harness CI | accepted |
