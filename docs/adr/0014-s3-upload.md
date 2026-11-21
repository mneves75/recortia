# ADR-014: Optional upload to a person's own S3-compatible bucket

**Status:** Proposed (2026-11-21), awaiting the owner's signature. SPEC §13 requires an
owner-signed threat model before any further FR-15 provider is built; the coordinator's
delegation does not cover that signature. Nothing is built.
**Requirements:** FR-15, NET-01, EXP-02, RED, SPEC §13 "Optional S3-compatible sharing" ·
Program 2026-11 B-9 (S3 provider) · **Verification:** `S3SignerTests` (AWS Signature Version 4
published test vectors), `S3UploaderTests` (injected transport), bilingual E2E `s3-upload`
(synthetic endpoint)

## Context

ADR-006 delivers upload to a private GitHub repository. SPEC §13 allows an S3-compatible
provider with these rules: upload only a reviewed `ShareSnapshot`; user-owned destination;
Keychain credentials; explicit destination and visibility confirmation; transport security;
least-privilege bucket/prefix access; cancellation and tested retries; one object key per
upload intent; no automatic public ACLs; an unguessable URL is not authentication; private
presigned access by default; show link expiry; explain that local deletion, remote deletion
and link revocation differ; never forward credentials across redirects; test each provider
rather than trusting "S3-compatible"; no Recortia backend.

## Threat model

- **Adversary.** A malicious or misconfigured endpoint (a redirect, an oversized or malformed
  response, a host that is not the one configured); a network observer; a stale or replayed
  upload intent; a person who later receives a presigned link.
- **Forbidden outcomes.** (F1) the secret access key leaves the Keychain other than as an input
  to the local HMAC signer: never in preferences, logs, a URL, a header, or a request to any host
  but the configured one; (F2) anything but an immutable `ShareSnapshot` is uploaded;
  (F3) an upload starts without the person's explicit action for that image; (F4) an object is
  made public, or a request carries an ACL or policy change; (F5) an existing remote object is
  overwritten or deleted.
- **Accepted residual.** A presigned link works for anyone holding it until it expires, and
  contains the access key ID (not the secret) and a signature; whoever controls the bucket can
  read, keep or publish what was uploaded; a link already copied cannot be revoked by Recortia
  (deleting the object or rotating the key can).

## Decision

1. **Explicit uploads only.** One export action, "Upload to S3", in the editor's export menu and
   the quick-action thumbnail, offered only while a destination is configured. No automatic
   upload after capture in this ADR (that would need ADR-006's sealed-consent machinery and a
   change here). The upload goes through the existing export pipeline and masking admission like
   Copy and Save.
2. **Destination and credentials.** Settings › Uploads gains an S3 section: endpoint (HTTPS URL,
   validated once: scheme https, host present, no user info, no query or fragment), region,
   bucket, optional key prefix, path-style or virtual-hosted addressing, and link lifetime
   (1 hour by default, 1 minute to 7 days, the Signature Version 4 maximum). The access key ID
   and secret live in the app-scoped, device-only Keychain; preferences hold only the destination.
   Saving the destination shows a confirmation that names the bucket and endpoint and says the
   bucket must stay private.
3. **Signing in-house, no SDK.** Requests are signed with AWS Signature Version 4 using CryptoKit
   HMAC-SHA256 in one MacPlatform type, verified against AWS's published test vectors. No AWS SDK
   dependency. The payload hash is computed over the exact bytes sent.
4. **Transport.** An ephemeral `URLSession` (no cookies, no cache, no credential storage), HTTPS
   only, redirects refused by the delegate (the request fails; no credential is ever re-sent to
   another host), request body at most 8 MiB, response bodies read to at most 64 KiB.
5. **One key per intent, never overwrite (F5).** Each upload intent gets
   `<prefix>/<UUID>.<png|jpg|heic>` once. The PUT carries `If-None-Match: *`; a 412 means the
   key exists, and Recortia then issues one HEAD and treats a matching `Content-Length` and
   `ETag` (the MD5 of the bytes for a single-part PUT) as "already uploaded", anything else as a
   refused conflict. A provider that ignores `If-None-Match` is not offered until it passes the
   compatibility check (7). No DELETE, no ACL, no policy, no multipart, no copy request is ever
   built: the signer accepts only `PUT` and `HEAD` on an object key, and `GET` only for presigning.
6. **No public objects (F4).** No `x-amz-acl` or grant header is ever sent. The success result
   offers a presigned GET link with the configured lifetime, shown with its expiry time, copied
   only on an explicit click. The Settings text explains that deleting the local file, deleting
   the remote object and a link's expiry are different things.
7. **Provider compatibility is tested, not assumed.** A "Test destination" button uploads a
   1×1 synthetic PNG to `<prefix>/recortia-check-<UUID>.png` and checks: a conditional PUT
   succeeds, a second conditional PUT to the same key is refused with 412, HEAD returns the
   expected length and ETag, a presigned GET returns the bytes, and an unsigned anonymous GET of
   the same object is refused (403; anything else means the bucket or prefix is readable by
   anyone, and the destination is refused). The probe image is a synthetic document rendered
   through the export pipeline into a `ShareSnapshot`, like every other upload. Upload is enabled only after
   it passes for the current destination; the result is stored with the destination and
   invalidated when any destination field changes. The check object stays (no DELETE, per 5);
   the Settings text says so.
8. **Retries and cancellation.** No automatic retry after a PUT is sent; a timeout or
   cancellation after sending reports "may have uploaded". Retry is bound to the original
   immutable `ShareSnapshot`, destination and key; if the document's revision or privacy epoch or
   the destination changed, Retry is refused and the person starts a new upload. Retry first
   sends HEAD: a matching length and ETag means done, any other existing object is a refused
   conflict, and only a missing object gets the conditional PUT again. Cancellation before
   sending sends nothing. Settings recommends enabling bucket versioning, which keeps an earlier
   object even if a provider ignored the precondition.

## Alternatives

- **The AWS SDK for Swift.** Rejected: a large dependency tree for two request types, and its
  credential chain reads environment variables and shared config files Recortia must not touch.
- **Automatic upload after capture**, as GitHub has. Deferred: it needs sealed consent bound to
  each intent (ADR-006) and a separate decision.
- **Public-read objects with unguessable names.** Rejected by SPEC §13.
- **Delete the compatibility-check object.** Rejected: a DELETE permission and request path is
  exactly what (5) forbids; a 1×1 synthetic image is harmless.

## Review ledger

| Round | Finding | Outcome |
|---|---|---|
| 1 | A bucket policy granting anonymous reads makes the probe and every upload public | Fixed: anonymous GET of the probe must be refused (7) |
| 1 | A gateway that drops `If-None-Match` lets a retry overwrite after a lost response | Fixed: Retry sends HEAD first, versioning recommended (8); a provider that silently drops the precondition on the first PUT remains possible and is the owner's call to accept |
| 1 | The probe could bypass `ShareSnapshot` | Fixed (7) |
| 1 | Retry could re-render a newer revision | Fixed: Retry bound to the original snapshot, destination and key (8) |

Round 1 used a prompt about "ordinary events" with web access off; it is not a full adversarial
pass.

## Consequences

- **Testing here.** Signature Version 4 test vectors; the signer refuses any method or header
  outside the allowlist; redirect refusal; response bounds; `If-None-Match` and the 412 → HEAD
  path; "may have uploaded" on timeout after send; no request without an explicit action; only a
  `ShareSnapshot` reaches the uploader (construction test). The E2E scenario uses a synthetic
  endpoint and transport, never a real bucket.
- **Owner qualification (`awaiting_manual_validation`).** A real AWS bucket with a key limited to
  `s3:PutObject` and `s3:GetObject` on the prefix, and each other provider the owner wants listed,
  each through the compatibility check.
- **Credentials.** The owner creates and enters real keys; no agent reads, creates or uses them.
