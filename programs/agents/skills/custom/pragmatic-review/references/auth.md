# Authentication and authorization - the DEEP blockers checklist

Read by the blockers agent at DEEP depth when its prompt names this file,
after the step-1 sweep of `blockers.md`. Run the greps at the bottom on
`$D/diff` first, then walk the checklist against every route, handler,
middleware, token, session and policy the diff touches. A hit you cannot refute
is a blocker: name the attacker, the entry point and the gain, as `blockers.md`
says.

## Trigger

The `auth.md` row of the routing table in `first-pass.md` Phase 1.

## Checklist

The attacker is an authenticated user of another account or tenant unless
stated; the gain is in brackets.

### Missing and broken authorization

- A new route, resolver field, RPC method or websocket event with no auth guard,
  or registered outside the router or group that applies one [unauthenticated
  access]. Verify the middleware order: a guard added after the handler, or a
  path on an allowlist of public routes, does not protect it.
- An object loaded by an id from the path, query or body (`findById(req.params.id)`)
  with no ownership or tenant check before it is read, changed or deleted
  (IDOR, BOLA) [read or write another user's data]. Expect the lookup itself
  scoped: `WHERE id = $1 AND owner_id = $2`, not a check after the fetch.
- A check in the UI or on the list endpoint only, skipped by the detail,
  update, export or bulk endpoint [direct API call].
- Role, plan or `is_admin` read from the body, a header, an unsigned cookie or
  an unverified claim; self-service writes to `role` or `tenant_id` (see
  `database.md`, mass assignment) [privilege escalation].
- A tenant id taken from input instead of the authenticated principal; a cache
  key, queue job or background task that drops the tenant [cross-tenant read].
- A removed, commented-out or `if (!dev)` guard; a default-allow branch in a
  policy (`return true` on an unknown action, `catch` that permits)
  [authorization bypass].

### Authentication

- A password hash that is not Argon2id (m=19 MiB, t=2, p=1), scrypt, bcrypt
  cost 10+ or PBKDF2-SHA256 600k; a fast hash (`md5`, `sha1`, `sha256`) on a
  password; bcrypt on input over 72 bytes or pre-hashed with a bare SHA
  [offline cracking after a dump].
- Secret, token or reset-code comparison with `==` instead of a constant-time
  compare [timing oracle].
- Reset or magic-link tokens that are guessable (`Math.random`, timestamps,
  sequential ids), long-lived, reusable or not invalidated after use; a reset
  that does not end other sessions [account takeover].
- MFA enforced only in the UI flow, or a step skippable by calling the
  post-MFA endpoint directly; a code with no attempt limit; a "remember device"
  token that never expires [MFA bypass].
- No rate limit or lockout on login, reset, MFA verify or signup; errors
  that differ for unknown users [credential stuffing, enumeration].

### Sessions and cookies

- Session id not rotated on login [fixation]; an auth cookie without
  `HttpOnly`, `Secure`, `SameSite`, or `Domain` widened [theft via XSS].
- Logout, password change or role removal that leaves existing sessions or
  refresh tokens valid [persistence after revocation].

### Tokens: JWT, API keys

- `alg: none` accepted, the algorithm taken from the token header, or no
  `algorithms=[...]` pinned; HS and RS/ES keys mixed, so the public key verifies
  as an HMAC secret [forge any token].
- `decode` used where `verify` was meant (`jwt.decode`, `verify_signature:
  False`, `ignoreExpiration`) [forge any token].
- `exp`, `iss` or `aud` not required and checked; a token minted for one
  service accepted by another [token replay across services].
- A key from the token's `jku`, `x5u`, `jwk` or an unvalidated `kid` [attacker
  supplies the key; `kid` is also an injection and traversal vector].
- A short, hardcoded or shared HMAC secret; secrets or PII in claims (only
  base64); API keys stored unhashed [forgery, exposure, a DB read = API access].

### OAuth and OIDC

- Authorization code flow without PKCE, or the implicit flow
  (`response_type=token`) [code or token interception].
- No `state` (or OIDC `nonce`) generated, bound to the session and checked on
  callback [login CSRF, account linking to the attacker's identity].
- Redirect URI matched by prefix, substring, regex or wildcard instead of exact
  string; a `next` or `returnTo` passed through unvalidated [code or token
  theft via open redirect].
- ID token not verified (signature, `iss`, `aud` equal to our client id,
  `exp`, `nonce`); identity taken from an unverified `email` claim or matched
  by email across providers [account takeover].
- Refresh tokens not rotated or sender-constrained; tokens in `localStorage`
  or a URL [replay after XSS or a log leak].

### Browser boundary: CSRF and CORS

- A state-changing `GET`; a cookie-authenticated `POST`, `PUT` or `DELETE` with
  CSRF protection disabled (`csrf_exempt`, `csrf: false`) and no `SameSite`
  [actions as the victim].
- CORS that reflects the `Origin` header, allows `null`, or matches by
  substring or unanchored regex, together with `credentials: true`
  [cross-site reads of authenticated responses].

## Grep, on the diff

Run all five in one turn. Each matches added lines only (`^\+`), so line
numbers stay those of `diff`. A hit is a lead: read the hunk.

```sh
rg -n -i '^\+.*(@(Public|AllowAnonymous|PermitAll|csrf_exempt)|skip_before_action|permitAll\(|isPublic|allowUnauthenticated|auth:\s*false|requireAuth\s*=\s*false)' "$D/diff"
rg -n -i '^\+.*(alg["'\'']?\s*[:=]\s*["'\'']none|jwt\.decode|verify_signature|ignoreExpiration|algorithms?\s*[:=]|jku|x5u|\bkid\b)' "$D/diff"
rg -n -i '^\+.*\b(md5|sha1|sha256|createHash|hashlib\.(md5|sha1|sha256))\b.*(pass|pwd|secret|token)' "$D/diff"
rg -n -i '^\+.*(Access-Control-Allow-(Origin|Credentials)|origin:\s*(true|\*)|credentials:\s*true|SameSite\s*=?\s*None|httpOnly:\s*false|secure:\s*false|csrf.{0,20}(false|disable))' "$D/diff"
rg -n -i '^\+.*(redirect_uri|returnTo|return_to|next=|response_type=token|startsWith\(.*(http|redirect)|req\.(body|query|headers)\.(role|isAdmin|is_admin|tenant|tenantId|userId))' "$D/diff"
```

## Sources

- https://top10.owasp.org/2025/A01_2025-Broken_Access_Control/
- https://top10.owasp.org/2025/A07_2025-Authentication_Failures/
- https://owasp.org/API-Security/editions/2023/en/0xa1-broken-object-level-authorization/
- https://cheatsheetseries.owasp.org/ (Authentication, Authorization, Session
  Management, Password Storage, JSON Web Token, OAuth2, CSRF Prevention)
- https://www.rfc-editor.org/rfc/rfc9700 (OAuth 2.0 Security Best Current Practice)
