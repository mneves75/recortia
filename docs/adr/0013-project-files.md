# ADR-013: Recortia project files keep edits, never the pixels a secure mask hid

**Status:** Proposed (2026-11-21) by the coordinator for the plan's scheduled ADR stop (the plan's
"threat-model ADR: source pixels under masks"), under the owner's 2026-11-20 delegation
(`docs/specs/program-2026-11/decisions.md`). Accepted only if its fresh-context review finds no
path to a forbidden outcome; the owner may overrule it before the release that ships it.
**Requirements:** FR-06 (secure redaction), FR-14 (import), Program 2026-11 B-8 ·
**Verification:** `ProjectFileTests`, `ProjectSnapshotConstructionTests`, RED-family project tests,
bilingual E2E `project-files`

## Context

Today an edit lives only while its editor is open: every export flattens it through
`ExportPipeline` → `ShareSnapshot`, and the invariant says every save, copy and drag goes that way.
People want to save an editable document (layers, annotations, masks, framing) and open it later,
and to see it in Finder's Quick Look.

An editable document holds source pixels. A secure mask is, by contract, source-pixel replacement,
"not a removable overlay" (AGENTS.md). A project file that stored the original pixels with the mask
as an object on top would be exactly a removable overlay: anyone with the file could delete the
mask. Cosmetic effects (blur, pixelate, an opaque shape) are already documented as not secure
(`redaction.cosmeticWarning`). A magnifier callout samples source pixels from one place and draws
them in another; FR-06 gives a mask over a magnifier destination-only coverage in exports.

A project file is also untrusted input: someone else's `.recortia` file may be malformed or hostile.

## Threat model

- **Adversary.** (a) A person who receives a `.recortia` file and wants what a secure mask hid;
  (b) a crafted `.recortia` package: malformed or huge JSON, huge or malformed images, extra files,
  links (symbolic or hard), a directory swapped while it is read, path-like names, references to
  missing assets, non-finite geometry, pathological mask lists, an unknown version.
- **Forbidden outcomes.** (F1) any pixel a secure mask covered at save time is recoverable from a
  package Recortia wrote; (F2) opening reads outside the package, follows a link, reads or decodes
  beyond the import limits, or hangs or crashes the app; (F3) opening a project runs an export, an
  upload, a network request, recognition, masking or any other automatic action; (F4) the Quick
  Look extension reads anything but the package's own `preview.png`, follows a link, or decodes
  beyond its bound.
- **Accepted residual.** Pixels under cosmetic effects are stored as they are, as the cosmetic
  warning already says; annotation text and layer layout are stored as the person wrote them. A
  package's preview shows whatever its author put there: someone who crafts or edits a package
  already holds its pixels, so a misleading preview discloses nothing they did not have.

## Decision

1. **A document package.** `<name>.recortia` is a directory package with an exported type
   `dev.mvneves.recortia.project` (conforms to `com.apple.package`), registered by the production
   app only. It holds exactly:
   - `project.json`: `{ "format": 1, "document": <Document> }`, sorted keys. Undo history, pins and
     the masking state are not stored.
   - `assets/<asset UUID>.png`: one lossless PNG per asset referenced by the document, holding the
     stored source pixels. Assets with no layer are not written and are removed from the stored
     document.
   - `preview.png`: the sanitized flattened output, at most 1024 px on its long side.
2. **Saving burns secure masks into the stored pixels (F1).** A project save goes through a new
   `ProjectSnapshot`, built only inside Imaging (the only holder of raw pixels), like
   `ShareSnapshot`:
   - **One frozen state.** The save captures one session (document, revision, privacy epoch) and
     builds every member, the preview included, from it. It is refused while automatic masking is
     pending, as an export is.
   - **Burn with the renderer's own coverage.** For every written asset, the coverage the secure
     renderer computes (stored source regions and the current mapping of every mask rectangle
     through every layer of that asset: crop offset, mirror, rotation, scale, translation, clipped
     and rounded outward) is filled exactly as the renderer fills it, before encoding. One shared
     function computes that coverage for both paths; a mapping failure refuses the save.
   - **Magnifiers.** A save is refused, with a message naming the reason, while a secure mask
     overlaps a magnifier callout's destination (the magnified source would survive outside the
     mask). The person deletes or moves the callout or the mask, or exports a flattened image.
   - The masks stay in the document, so the reopened editor shows the same result; moving one
     afterwards uncovers only the fill. Encoding is a clean re-encode with no source metadata.
   - `ProjectSnapshotConstructionTests` enforces that only Imaging constructs it, as
     `ShareSnapshotConstructionTests` does for exports; the AGENTS.md invariant becomes: every
     flattened save, copy and drag goes through `ShareSnapshot`; a project save goes through
     `ProjectSnapshot`.
   - **Atomic publication.** The package is written to a private temporary directory on the
     destination volume, then moved into place in one replace (`FileManager.replaceItemAt` or
     rename), only if the session's identity, revision and privacy epoch still match. A failure
     leaves the previous package untouched; no member is ever overwritten in place.
3. **Opening is admission, once, at the door (F2, F3).** File › Open and opening from Finder,
   including cold-launch requests, recognize a `.recortia` package before the image importer and
   send it to one `ProjectReader`, which validates everything before an editor exists:
   - **Descriptor-relative reads.** It opens the package directory, then `assets`, each with
     `O_DIRECTORY | O_NOFOLLOW`, and every member with `openat` relative to those descriptors with
     `O_NOFOLLOW`. Every member must be a regular file with a link count of 1 (`fstat` on the open
     descriptor); the directory listing must be exactly the expected names; anything else is
     refused.
   - `project.json` at most 4 MiB; `format` must be 1; it must decode into a `Document` whose
     invariants hold (every referenced asset present, finite geometry, unique IDs, positive sizes).
   - **Work budget before any decode.** At most 32 assets, 64 masks with 64 rectangles each, 256
     annotations and 32 callouts. Before decoding pixels, each asset's PNG header dimensions are
     read from the bounded bytes and checked against the per-image limit and the *remaining*
     `maxOpenedPixelArea` budget; then each decodes through the existing bounded decoder. The sum
     of mask-rectangle areas mapped into each asset must stay within 8× that asset's pixel area.
   - `preview.png` is never read by the app.
   - A refusal is one content-free error ("This Recortia project can't be opened.").
   - **No automatic work.** A project opens through its own route and never through
     `ImportCoordinator.onImported`: no automatic export, upload, recognition or masking sweep;
     the document opens in an editor with its stored masks.
4. **Quick Look reads only the preview (F4).** A Quick Look preview extension (sandboxed appex in
   the production app, entitlement `com.apple.security.app-sandbox` only) opens the package and
   `preview.png` with the same descriptor-relative, no-follow, link-count-1 rules, reads at most
   8 MiB, checks the PNG signature and header dimensions (at most 1024 px on each side) from those
   bytes, and decodes with ImageIO's thumbnail path. It never reads `project.json` or `assets/`.
5. **Releases.** The appex follows ADR-012's signing and entitlement-gate rules (an exact
   entitlement set, Hardened Runtime, checked by `check-release-entitlements.py`).

## Alternatives

- **Store original pixels and keep masks removable** (a layered document like a design file).
  Rejected: it turns every secure mask into a removable overlay, breaking FR-06 and the AGENTS.md
  contract, and a shared project would leak what people believed they had redacted.
- **Ask on each save whether to burn masks in.** Rejected: a choice that can leak redacted content
  will be made wrongly, and the editor already lets people delete a mask before saving.
- **Map masks back through magnifiers and burn their sources.** Deferred: it changes what the
  magnifier shows elsewhere on the canvas; refusing is simpler and safe.
- **A single-file archive (zip) instead of a package.** Rejected: an archive reader adds
  decompression bounds (zip bombs) and path handling a package's fixed names avoid.
- **A Quick Look thumbnail rendered from the document.** Rejected: it would need the extension to
  read assets and run the renderer; the stored sanitized preview keeps the extension tiny.

## Review ledger

| Round | Finding | Outcome |
|---|---|---|
| 1 | A mask over a magnifier destination leaves the magnified source in the asset | Fixed: save refused (2) |
| 1 | An edit during an asynchronous save mixes members; an interrupted overwrite leaves old members | Fixed: one frozen state, staged package, atomic replace on matching revision (2) |
| 1 | A swapped `assets` directory or a hard link escapes the package | Fixed: descriptor-relative no-follow reads, link count 1 (3) |
| 1 | The aggregate pixel budget is checked after decoding | Fixed: header dimensions against the remaining budget before decode (3) |
| 1 | A small manifest with thousands of mask rectangles stalls the first render | Fixed: counts and mapped-area budget (3) |
| 1 | A project opened through the image importer starts recognition and masking | Fixed: its own route (3) |
| 1 | A linked preview redirects the extension | Fixed (4) |
| 1 | A replaced preview shows an unredacted image | Declined: the author of a package holds its pixels; residual (Threat model) |

Round 1 used a prompt about "ordinary events" with web access off, after the provider's content
filter refused the adversarial wording; it is not a full adversarial pass.

## Consequences

- **The invariant changes in one place** (Decision 2) and gains a construction test.
- **Testing here.** RED-family: a planted secret under a secure mask is absent from every byte of
  the saved package (decode every asset; scan the JSON), across rotated, mirrored, cropped and
  duplicated layers; reopening shows the fill; a mask over a magnifier destination refuses the
  save; an edit during the save does not publish. `ProjectFileTests`: round trip, and every refusal
  in Decision 3 with planted packages (symbolic and hard links, a swapped directory, extra file,
  huge JSON, bad version, missing asset, NaN, too many assets or rectangles, an oversized header).
  The bilingual E2E `project-files` scenario saves, reopens and compares, and opens a planted
  hostile package expecting the error.
- **Owner qualification (`awaiting_manual_validation`).** Finder double-click and Quick Look on the
  installed, signed app.
