# Spec Delta

## Purpose

Lets the maintainers keep the curated catalog current: a script verifies the entries against the live web, refreshes their recorded details, and regenerates the bundled catalog, so dead or changed links are found and replaced instead of shipping to users.

## ADDED Requirements

### Requirement: Curated source of truth
The repository SHALL hold a curated source file from which the bundled catalog is generated. It MUST list the selected entries and the verified alternates, each with a reason when it is not selected, and the rejected candidates with the reason and the date. The bundled catalog MUST contain only selected entries and MUST NOT be edited by hand.

#### Scenario: Alternate kept
- **WHEN** a candidate passed every check but was not chosen
- **THEN** it stays in the source as an alternate in its category, ready to replace a dead entry

#### Scenario: Rejected remembered
- **WHEN** a candidate was rejected for being too large
- **THEN** the source records the size and the date, so nobody researches it again

### Requirement: Selection rules
An entry SHALL qualify for selection only if its address is HTTPS, a plain request without cookies or sign-in returns a PDF whose content starts with the PDF signature, its size is at most 20 MiB, and it needs no form, login or consent wall. A military entry MUST also carry a public-release statement in its own text, and a restricted or export-controlled one MUST NOT be selected.

#### Scenario: Form-gated paper
- **WHEN** a whitepaper's PDF is reachable only after an email form
- **THEN** it does not qualify

#### Scenario: Restricted military manual
- **WHEN** a military manual's text carries a distribution limitation
- **THEN** it does not qualify, even if the file is reachable

### Requirement: Check command
The script SHALL provide a check command that verifies every entry in the source against the live web and reports, per entry, one result: ok, changed (size or checksum differs from the record), too large, not a PDF, blocked (the host refuses non-browser clients), gone, or unreachable. It MUST NOT modify any file, and MUST exit with a failure status when any selected entry is not ok or changed.

#### Scenario: All good
- **WHEN** every selected entry still matches its record
- **THEN** the command reports all ok and exits successfully

#### Scenario: Dead link
- **WHEN** a selected entry now redirects to an HTML page
- **THEN** the report marks it gone, names its category, and the command exits with a failure status

#### Scenario: Silent update
- **WHEN** a manual was replaced by a new revision of a different size
- **THEN** the report marks it changed and shows the old and new size

### Requirement: Transient failures
The check MUST retry a failing request, with a pause, before reporting an entry as gone or unreachable, and MUST treat a server error or a rate-limit answer as unreachable, not gone. It SHALL space requests to the same host, and SHALL identify itself honestly.

#### Scenario: Flaky host
- **WHEN** a host answers 500 on the first request and 200 on the retry
- **THEN** the entry is ok

#### Scenario: Rate limit
- **WHEN** a host answers "too many requests" every time
- **THEN** the entry is reported unreachable, not gone

### Requirement: Refresh command
The script SHALL provide a refresh command that re-measures each entry that still qualifies and updates its recorded size, page count, title, checksum and verification date in the source. Entries that no longer qualify MUST be left as they are and listed in the report.

#### Scenario: Updated record
- **WHEN** a manual grew from 5.2 MB to 5.4 MB and still qualifies
- **THEN** the source records the new size, checksum and date

#### Scenario: Failing entry untouched
- **WHEN** an entry is gone
- **THEN** refresh leaves its record unchanged and lists it as needing attention

### Requirement: Rebuild command
The script SHALL provide a rebuild command that regenerates the bundled catalog from the source: selected entries only, in a stable order, with identical output for identical input. When a selected entry fails, rebuild MUST replace it with a qualifying alternate of the same category and kind when one exists, and MUST report each replacement and each entry it could not replace.

#### Scenario: Replacement
- **WHEN** a selected Yacht catalog is gone and a verified Yacht catalog alternate qualifies
- **THEN** the alternate is selected in its place and the report says so

#### Scenario: No alternate
- **WHEN** a failing entry has no qualifying alternate
- **THEN** it is left out of the bundled catalog and the report says the category is now one entry short

#### Scenario: Reproducible
- **WHEN** rebuild runs twice on the same source
- **THEN** the bundled catalog is byte-identical both times

### Requirement: Catalog integrity
Before writing, rebuild SHALL validate the result: unique entry identifiers, only HTTPS addresses, every category present, every entry within 20 MiB, and a total count that the report compares with the previous catalog. A failed validation MUST leave the bundled catalog unchanged.

#### Scenario: Duplicate address
- **WHEN** two entries share one address
- **THEN** rebuild reports the duplicate and writes nothing

### Requirement: Maintenance report
Each command SHALL end with a summary by category: how many entries are ok, changed, replaced and needing attention, so a maintainer sees at a glance whether the catalog needs a new release.

#### Scenario: Summary
- **WHEN** a check finishes
- **THEN** a table lists each category with its counts and the command's final line states how many entries need attention
