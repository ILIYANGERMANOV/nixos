# Common attacks - the DEEP blockers checklist

Read by the blockers agent at DEEP depth, after the step-1 sweep of
`blockers.md` and before any topic reference its prompt names. It condenses the OWASP Top 10:2025 and the 2025 CWE Top
25 to what a diff can show. Run the greps at the bottom on `$D/diff` first,
then walk the checklist against every place the diff takes input from outside
the process. A hit you cannot refute is a blocker: name the attacker, the entry
point and the gain, as `blockers.md` says.

## Trigger

Always, at DEEP depth. The topic references go deeper on their own ground; this
file covers what crosses all of them.

## Checklist

The attacker is anyone who can send the input: an anonymous request, a file, a
webhook, a queue message, a third-party API response. The gain is in brackets.

### Injection and code execution

- A shell command built from input: `exec`, `system`, `popen`, `child_process.exec`,
  `subprocess(..., shell=True)`, backticks, `sh -c "$x"`, Nix `runCommand` with
  interpolated input [RCE]. Expect an argv array with no shell and `--` before
  user-supplied arguments (option injection: `git`, `tar`, `curl`, `find`).
- `eval`, `new Function`, `vm.runInContext`, `import()` or `require()` of a
  path from input; a template compiled from input (`render_template_string`,
  `Template(input)`, `ejs.render(input)`) [RCE, SSTI].
- Deserialising untrusted bytes: `pickle`, `yaml.load` without `SafeLoader`,
  Java `ObjectInputStream`, .NET `BinaryFormatter`, PHP `unserialize`,
  `Marshal.load`, `node-serialize` [RCE through gadget chains]. Expect JSON or
  a safe loader with a schema.
- XML parsed with external entities or DTDs enabled [XXE: file read, SSRF].
- LDAP, XPath or CRLF header injection from unescaped input [auth bypass].
- Prototype pollution: a deep merge or `set(obj, path, v)` from JSON input not
  blocking `__proto__`, `constructor`, `prototype` [property injection, RCE].

### Browser-side

- XSS: input reaching `innerHTML`, `outerHTML`, `document.write`,
  `dangerouslySetInnerHTML`, `v-html`, `{@html}`, `|safe`, `mark_safe`,
  `html_safe`, `bypassSecurityTrust*`, or an `href` or `src` that can be
  `javascript:` [session theft, actions as the victim]. Expect framework
  escaping or a sanitizer such as DOMPurify; a CSP loosened with
  `unsafe-inline` or `unsafe-eval` is a finding.
- Open redirect: `redirect(req.query.next)` or `location = param` without an
  allowlist or a same-origin check; `startsWith('/')` admits `//evil.com`
  [phishing, OAuth token theft].
- A `postMessage` handler without an `origin` check [cross-origin theft].

### Server-side requests and files

- SSRF: the server fetches a URL, host or webhook target from input with no
  allowlist, or a blocklist that misses `169.254.169.254`, IPv6, decimal IPs,
  DNS rebinding and redirects [cloud metadata credentials, internal services].
  Expect an allowlist, resolution then IP check, and redirects disabled.
- Path traversal: input joined into a filesystem path (`path.join(base, x)`,
  `open(dir + name)`, `send_file`, zip or tar extraction) without resolving
  and checking it stays under the base [read `/etc/passwd`, overwrite code;
  Zip Slip].
- File upload: type checked by extension or `Content-Type` only; stored under
  the web root or served inline from the app origin; the client's filename
  used; no size limit; SVG or HTML accepted [stored XSS, webshell, disk
  exhaustion]. Expect a generated name, content sniffing, size limits and a
  separate domain or `Content-Disposition: attachment`.

### Supply chain

- A new dependency: check the name against typosquats and the real project,
  its age and maintainers, install scripts (`postinstall`, `setup.py`), and
  known advisories (`npm audit`, `pip-audit`, `osv-scanner`, GitHub advisory
  database) [code execution at install and runtime].
- A dependency on a git or tarball URL, a branch, `*` or `latest`; a lockfile
  `resolved` URL off the registry [a mutable or attacker-controlled source].

### Crypto and randomness

- `Math.random`, `random.random`, `rand()`, timestamps or UUIDv1 for tokens,
  ids that guard access, nonces or salts [guessable values]. Expect
  `crypto.randomBytes`, `secrets`, `getrandom`.
- `MD5`, `SHA1`, `DES`, `RC4`, ECB mode, a static IV or nonce, a hardcoded key,
  or a hand-rolled MAC instead of HMAC or an AEAD [decryption, forgery].
- TLS verification turned off: `verify=False`, `rejectUnauthorized: false`,
  `InsecureSkipVerify`, `NODE_TLS_REJECT_UNAUTHORIZED=0`, `curl -k` [MITM].

### Abuse, races and errors

- No rate limit, size limit or pagination cap on a costly or auth-adjacent
  endpoint: login, reset, OTP, signup, search, export, upload, LLM calls
  [brute force, cost or resource exhaustion; CWE-770].
- Check-then-act on balances, coupons, invites, quotas or one-time tokens
  without a transaction, row lock or unique constraint [double spend, reuse
  by racing requests].
- An error path that fails open: `catch` returning success or skipping the
  check, a missing `return` after sending a 403, a default branch that allows
  [bypass]. Stack traces, SQL errors or internal hosts returned to clients
  [reconnaissance; A10:2025].
- `DEBUG=True`, `/actuator`, GraphQL introspection or playground left on in
  production [information leak, sometimes RCE].

## Grep, on the diff

Run all five in one turn. Each matches added lines only (`^\+`), so line
numbers stay those of `diff`. A hit is a lead: read the hunk.

```sh
rg -n '^\+.*(\beval\(|new Function\(|exec\(|execSync\(|spawn\(.*shell:\s*true|shell=True|os\.system\(|popen\(|render_template_string|Template\(|pickle\.loads?|yaml\.load\(|unserialize\(|ObjectInputStream|BinaryFormatter|Marshal\.load)' "$D/diff"
rg -n '^\+.*(innerHTML|outerHTML|document\.write|dangerouslySetInnerHTML|v-html|\{@html|\|\s*safe\b|mark_safe|html_safe|bypassSecurityTrust|unsafe-inline|unsafe-eval)' "$D/diff"
rg -n -i '^\+.*(redirect\(.*(req|request|params|query)|location(\.href)?\s*=.*(param|query|search)|(fetch|axios|requests\.(get|post)|http\.get|urlopen|got)\(.*(req|request|params|query|body|url)|path\.join\(.*(req|params|query|body)|send_?file\(|extractall\()' "$D/diff"
rg -n -i '^\+.*(Math\.random|random\.random|\bmd5\b|\bsha1\b|\bDES\b|RC4|ECB|verify\s*=\s*False|rejectUnauthorized:\s*false|InsecureSkipVerify|TLS_REJECT_UNAUTHORIZED|curl -k\b|DEBUG\s*=\s*True)' "$D/diff"
rg -n '^\+\s*"[^"]+":\s*"(git\+|https?://|github:|\*|latest)' "$D/diff"
```

The last grep reads `package.json`-style dependency lines; for other
ecosystems read the manifest and lockfile hunks by hand.

## Sources

- https://top10.owasp.org/2025/
- https://cwe.mitre.org/top25/archive/2025/2025_cwe_top25.html
- https://cheatsheetseries.owasp.org/ (OS Command Injection, Deserialization,
  XSS, SSRF, File Upload, Unvalidated Redirects, Prototype Pollution,
  Vulnerable Dependency Management)
- https://portswigger.net/web-security/race-conditions
