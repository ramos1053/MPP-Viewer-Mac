# Changelog

## [0.1.1] - 2026-10-29

### Fixed
- **The packaged app failed to open any project at all**, showing "Helper process closed its output
  unexpectedly." The signed Helper (self-contained .NET) was being killed by the OS on startup —
  CoreCLR's JIT needs executable+writable memory pages, which Hardened Runtime blocks without an
  explicit entitlement. Added `Helper/entitlements.plist` and sign `MppHelper` with it. If you hit this
  on v0.1.0, download v0.1.1 instead.

## [0.1.0] - 2026-10-29

### Added
- **Five views**: Gantt (WBS table + chart), Timeline, Network (PERT diagram), Calendar (Month, Team,
  and Task Usage modes), and Resources.
- **Live critical-path calculation**: a real backward-pass CPM engine (late dates, float) runs on every
  edit, not just a display of whatever a file already carried in — works for a project built entirely
  from scratch, not only imported files.
- **Calendars editor**: define working weeks and holiday/exception calendars per project; saved and
  round-tripped for real (not yet consumed by the scheduler — see README's "What it does not do").
- **Project-wide budget tracking**: planned vs. progress-weighted earned cost, using the same Budget
  Resource / Project Summary Task convention Microsoft Project itself uses.
- **Export and print**: CSV of the task list; PDF, PNG, or direct printing of a Timeline snapshot.
- **Find, Find Next/Previous, and Find and Replace** across task names and notes.
- **Full in-app Help system**, searchable, covering every feature and keyboard shortcut.
- **Undo/redo** for essentially every edit.
- Reads Microsoft Project (`.mpp`, `.mpt`), Project XML/MSPDI, MPX, GanttProject, Primavera P6, Asta
  Powerproject, SureTrak, Phoenix Project Manager, and other formats via MPXJ.Net. Always saves as
  Project XML (MSPDI) — see README for why.

### Known limitations
- No working-time-calendar-aware scheduling yet (calendar-day arithmetic only — see README).
- No toolbar customization (removed after it reliably crashed on this AppKit version).
