# Security hardening implementation

Non-normative implementation record. Scope: the eight findings from the local
Codex Security scan of `ea5b044`, grouped into six repairs. No live AWS writes,
Keychain key export, installation, push, notarization or release publication.

1. Authenticate Sparkle 2.10.0 using its pinned upstream archive checksum before
   copying framework contents or executing helpers. Stage verified inputs privately;
   release compilation uses a fresh scratch directory. Reject tampered inputs before
   any helper or signing command runs.
2. Bind credential candidates to the verified account and stable principal, covering
   default/custom SSO and other providers. Check newly rotated credentials using
   those exact credentials, invalidate old generations and notify the workspace.
   Test role changes, normal renewal, stale requests and concurrent verification.
3. Prepare a bounded private upload snapshot before confirmation, bind SHA-256 to
   the intent and the S3 request, and include ctime in file fingerprints. Test mtime
   restoration, preparation cancellation, snapshot cleanup and changed bytes.
4. Preserve listed ETag/size, require conditional downloads, enforce byte/capacity
   budgets and anchor all destination operations to a retained directory descriptor.
   Test response replacement/overrun, low space, directory swaps and failure cleanup.
5. Carry the verified account into S3 browser/location/detail requests using expected
   owner conditions. Test request mapping, rejected owners and clearing stale results.
6. Require Sparkle signed feeds and validation before extraction. Sign and verify
   candidate XML before atomic publication; failures preserve the prior feed.
   Signing does not establish freshness or server availability.

Verification: focused offline Swift/Python regressions, full Swift build/test and
Harness gates; no actual disk exhaustion or real cloud mutation. Update affected
README/script documentation and ROADMAP, review the diff, then commit locally.

Status: source repairs and offline verification complete.

Validation (2026-10-11): 806 strict-concurrency Swift tests, 39 Python tests,
all five fixed Harness checks, shell syntax, documentation links, Markdown rule
structure, Gitleaks 8.30.1, and diff checks passed. Downloaded the pinned official
Sparkle archive, verified its SHA-256, and checked private extraction paths without
executing signing helpers. Real CryptoKit feed verification with an ephemeral
in-memory key accepted valid bytes and rejected equal-length tampering.

Limits: no full Codex Security rescan, live AWS acceptance, new distribution,
real signing-key access, installation, push or release. Published appcasts remain
unsigned empty placeholders until an authorized signed-feed publication. This
source change does not replace the currently distributed or installed application.
