# ADR-006 — Optional GitHub auto-upload

**Status:** Implementing owner request of 2026-10-01: “for auto-upload, use github”.
**Requirements:** FR-15 / NET-01 / EXP-02 / RED.

Use GitHub.com's repository Contents API with an existing user-configured private repository
and a fine-grained token restricted to it, Contents read/write. No Recortia backend, Enterprise
host, public destination, release assets, S3, repository creation or remote deletion.

Auto-upload is off initially. Saving the destination/token does not enable it. Separate
confirmation explains that each still capture uploads before later edits/redaction. Imports,
OCR-only captures and scrolling results do not upload automatically. Only an immutable
ShareSnapshot crosses this boundary. Tokens live in the app-scoped, device-only Keychain;
preferences contain destination and sealed consent, never tokens or image bytes.

## Safety and failure contract

- Fixed HTTPS api.github.com; no redirects, cookies/cache, spool files or request-body logs.
- Check repository identity, private status and non-archived state before accessing contents.
- Image bytes bounded to 8 MiB; responses to 2 MiB; encoding runs off MainActor.
  Contents lookups use object media, which omits inline content above 1 MiB. The response
  budget accommodates base64 for smaller files plus metadata and remains explicitly bounded.
- Recheck document/revision/privacy epoch and destination/consent immediately before PUT.
- Canceling an automatic batch prevents later sinks; an occupied batch reports an error.
- One screenshots/<UUID>.png or .jpg path per intent. GET before PUT; matching Git blob SHA
  recognizes completion. Conflicting bytes are refused; existing files are never overwritten.
- No automatic retry after PUT. Timeout/cancellation/malformed success can mean the upload
  completed; report that uncertainty. A provider-level retry uses the same intent UUID.
- Success exposes a validated GitHub link that opens only on an explicit click.

Git history retains binary files. Private links require authenticated GitHub access and have
no promised expiry. Repository visibility/collaborators can change after verification; the owner
must keep the destination private. Turning upload off does not remove remote copies or history.
Changing destinations leaves unused old Keychain entries; removal targets the selected entry.

The strongest alternative is release assets, which avoids commit growth but requires selecting
a release and does not improve private link lifecycle for this use case.

Tests use synthetic snapshots and an injected transport. E2E uses a synthetic remote sink
through the real app/pipeline. Live provider credentials/transfers require owner testing.

Sources: https://docs.github.com/en/rest/repos/contents and
https://docs.github.com/en/rest/repos/repos#get-a-repository (read 2026-10-01).
