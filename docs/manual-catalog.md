# Manual catalog

A new library is empty, and good public manuals take time to find. The catalog is a bundled list of 70 real, public PDFs
in nine categories (Automotive, Motorcycle, Ships, Yachts, Manufacturing, Wind turbines, Field service, Military and
Couchbase): manuals, product catalogs and whitepapers. The app links to each publisher's own file and never carries a copy.
This page is about the list itself and the script that keeps it current. For using the catalog in the app see
[using.md](using.md#manual-catalog).

## What the app does with it

`App/Resources/ManualCatalog.json` ships inside the app. Opening the catalog, browsing, searching and filtering make no
network requests. Importing an entry downloads the publisher's PDF to a temporary file and hands it to the same import as a
file from the Files app, so it is queued, indexed, synced and kept like any other document.

- The document's id is `catalog-<entry id>`, so the same entry is one document on every iPad that shares the library, and a
  deleted document makes its entry importable again. The two Couchbase whitepapers that are also the demo's bundled samples
  carry that sample's id (`documentId` in the entry), so importing one never creates a second copy.
- The document record keeps its **origin**: the entry and the address it was downloaded from. It survives re-indexing and
  sync, and the library shows the publisher's host in the document's details.
- The first download from a host says so, naming it, and asks first. Only the hosts of entries you choose are contacted, and
  nothing about you or your library is sent. The app identifies itself as `ManualBot/1.0`, sends no cookies, and does not
  pretend to be a browser.
- A download is accepted only if it starts with the PDF signature (whatever the address ends in), is at most 20 MiB (the
  import limit), and ends on an HTTPS address. A web page where the PDF used to be means the link has gone; a publisher that
  refuses non-browser clients is reported as such, and the entry offers **Open in browser**.
- The catalog records each file's SHA-256 as last verified. If a publisher has replaced the file the import still goes
  ahead, and the entry says the file was updated since the catalog was prepared.

## Which entries qualify

An entry is selected only if all of these hold, and the script checks them:

- its address is HTTPS and a plain request, with no cookies or sign-in, returns a PDF whose content starts with `%PDF-`;
- the file is at most 20 MiB;
- it needs no form, login or consent wall (a whitepaper behind an email form does not qualify);
- a Military entry also carries a public-release statement in its own text (for example "Distribution A" or "approved for
  public release"), and no restriction or export-control notice. Restricted manuals are never selected, even when the file
  is reachable.

Each category holds 7 to 8 selected entries and, besides them, **alternates**: entries that passed every check but were not
chosen (a near-duplicate of a selected one, a lighter rider handbook, an older edition). When a selected entry dies,
`rebuild` promotes a qualifying alternate of the same category and kind.

## The maintenance script

`scripts/manual-catalog.swift` is one Swift file. Run it from the repository root, with network access, on a Mac:

```sh
swift scripts/manual-catalog.swift check      # verify every entry against the live web; changes nothing
swift scripts/manual-catalog.swift refresh    # re-measure the entries that still qualify and update their records
swift scripts/manual-catalog.swift rebuild    # replace dead entries from the alternates, then regenerate the bundled catalog
```

It reads and writes `scripts/manual-catalog/curated.json`, the source of truth, and generates
`App/Resources/ManualCatalog.json`, which is never edited by hand. A run over all 182 entries downloads about 900 MB and takes
a few minutes; requests to one host are sequential with a pause, different hosts run side by side, and a request that fails
with a server error, a rate limit or a dropped connection is retried with a pause before it is reported.

### What `check` reports

One result per entry:

| Result | Meaning |
|---|---|
| `ok` | a PDF within the limit, matching the record |
| `changed` | still a valid PDF, but its size or checksum differs from the record: run `refresh` |
| `too large` | more than 20 MiB |
| `not a PDF` | the content is not a PDF and not a web page either |
| `restricted` | a Military entry without a public-release statement, or with a restriction |
| `blocked` | the host refuses non-browser clients (HTTP 401 or 403, or a firewall captcha) |
| `gone` | not found, or the address now returns a web page, or it redirects to a non-HTTPS address |
| `unreachable` | a server error, a rate limit or a network failure that outlasted the retries: it is never reported as `gone` |

It prints each category's entries, then a table of counts per category (ok, changed, replaced, attention; alternates are
counted apart) and a last line such as `0 need attention`. **Need attention** means a selected entry that is neither `ok`
nor `changed`; the exit status is 1 then, and 0 otherwise. `restricted` is a result of its own, beyond the seven above, so
that a Military manual that lost its public-release statement is not mistaken for a broken link.

### What `refresh` does

Re-measures every entry and, for those that still qualify, rewrites their size, page count, checksum, the title found inside
the PDF (`pdfTitle`; the curated `title` stays as written) and `verifiedAt`. An entry that no longer qualifies keeps its old
record and is listed. Run it when `check` reports `changed`, and once after adding entries.

### What `rebuild` does

1. Checks the selected entries.
2. For each one that fails, tries the alternates of its category and kind, in the order they are listed in the source, and
   promotes the first that qualifies. The failing entry becomes an alternate with a `reason` that says why it was retired
   (`Retired 2026-10-13, blocked: …`). A failing entry with no qualifying alternate is left out, and the report says the
   category is now one entry short.
3. Validates the result: unique ids and addresses, HTTPS only, every category present, every entry between 1 byte and 20 MiB
   with a checksum and a page count recorded, a known kind and category. The report compares the total with the previous
   catalog.
4. Writes `App/Resources/ManualCatalog.json` (sorted by category, then title; identical input gives identical bytes) and, if
   anything was replaced, the updated `curated.json`. **A failed validation writes nothing.**

`rebuild` uses the records in `curated.json`, not the live measurements, so run `refresh` first when `check` reports
`changed` entries. `--offline` skips the network and builds from the records alone.

### Options

| Option | Effect |
|---|---|
| `--selected` | check or refresh only the selected entries, not the alternates (about half the download) |
| `--only <id>,<id>` | only these entries |
| `--source <file>`, `--output <file>` | read another source, or write the catalog elsewhere (to try a change without touching the repository) |
| `--offline` | `rebuild` only: generate from the records, with no requests |
| `--retries <n>`, `--retry-pause <seconds>` | how often a transient failure is retried (3) and the base pause (5 s, growing; a server's `Retry-After` wins, up to 60 s) |
| `--spacing <seconds>`, `--parallel <hosts>` | the pause between requests to one host (1 s) and how many hosts are checked at once (8) |

## The source file

`scripts/manual-catalog/curated.json` has two lists:

- `entries`: every candidate that passed the checks, with `selected` true for those in the catalog. An entry has an `id` (a
  stable slug, kept for as long as the entry exists, because it names the document), `category`, `kind` (`manual`, `catalog`
  or `whitepaper`), `title`, `publisher`, `language`, `url`, `bytes`, `pages`, `sha256`, `licenceNote` and `verifiedAt`; a
  `notes` text for a selected entry or a `reason` for an alternate; and `documentId` when the PDF is also a bundled sample.
- `rejected`: candidates that were looked at and turned down, each with the `reason`, its `bytes` when known and the date, so
  nobody researches them again (too large, withdrawn, bot protection, form-gated, restricted distribution).

To add an entry, append it to `entries` with `"selected": false`, run `check --only <id>` and `refresh --only <id>`, then
set `"selected": true` for the entry it should join (or leave it as an alternate), and `rebuild`. To retire one for good, move
it to `rejected` with the reason.

## Before a release

```sh
swift scripts/manual-catalog.swift check            # expect "0 need attention"
swift scripts/manual-catalog.swift refresh          # only if check reported changed entries
swift scripts/manual-catalog.swift rebuild          # only if check reported entries that need attention
RUN_NETWORK_TESTS=1 swift test --filter ManualCatalogNetworkTests    # in Packages/Adapters
```

Then commit `scripts/manual-catalog/curated.json` and `App/Resources/ManualCatalog.json` together. The network test downloads
two real entries through the app's own downloader, so a host that blocks the app but not the script shows up there. Links
rot between releases and nothing here runs on a schedule: a dead link appears in the app as a failed row with a reason and a
retry, and leaves no partial file or document.

## Copyright

The catalog links, shows each entry's licence note, and imports only from the publisher's published address. Government
works are public domain; manufacturer and Couchbase documents are free to download but carry no grant to redistribute them,
which is why no PDF is bundled or mirrored.
