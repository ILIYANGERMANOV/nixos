# Databases - the DEEP blockers checklist

Read by the blockers agent at DEEP depth when its prompt names this file,
after the step-1 sweep of `blockers.md`. Run the greps at the bottom on
`$D/diff` first, then walk the checklist against every query, model, schema,
policy and migration the diff touches. A hit you cannot refute is a blocker:
name the attacker, the entry point and the gain, as `blockers.md` says.

## Trigger

The `database.md` row of the routing table in `first-pass.md` Phase 1.
Destructive statements, unbounded writes and missing down paths are the
irreversible-damage section of `blockers.md`: apply it to every migration, and
do not repeat it here.

## Checklist

The attacker is an authenticated user unless stated; the gain is in brackets.

### Injection

- A query string built by concatenation, `+`, `%`, `.format`, f-string,
  template literal or `sprintf` from anything not a constant [read or write any
  table, sometimes RCE via `COPY ... PROGRAM` or `xp_cmdshell`]. Expect bound
  parameters; trace the value to its source before refuting.
- ORM escape hatches fed input: `raw`, `extra`, `RawSQL`, `$queryRawUnsafe`,
  `$executeRawUnsafe`, `sequelize.literal`, `knex.raw`, `whereRaw`,
  `text()`, `createNativeQuery`, `@Query(nativeQuery)` with `+` [same].
  Tagged templates (`$queryRaw\`...\``, `sql\`...\``) are parameterised; a
  plain string passed to them is not.
- An identifier from input: `ORDER BY`, column, table or sort direction, which
  cannot be bound [injection]. Expect an allowlist map, not escaping.
- `LIKE` or regex built from input without escaping `%`, `_` or metacharacters
  [ReDoS on Mongo `$regex`, wildcard data scraping].
- NoSQL: a request body or query object passed straight into `find`,
  `findOne`, `update` or `where` (`{ password: { "$ne": null } }`); `$where`,
  `mapReduce` or `$function` with input; qs or JSON parsing that turns
  `user[$gt]=` into an operator [auth bypass, JS execution in the DB].
  Expect a cast to string, `sanitizeFilter`, or schema validation.

### Mass assignment

- A create or update built from the whole request body: `Model.create(req.body)`,
  `update(**request.data)`, `@ModelAttribute` on an entity, `fill($request->all())`,
  Rails `permit!`, a serializer with `fields = '__all__'` or `exclude` [set
  `role`, `is_admin`, `owner_id`, `tenant_id`, `balance`, `verified`]. Expect a
  DTO or an allowlist; a blocklist (`$guarded`, `exclude`) misses the next
  sensitive column added, which the existing endpoint then writes.

### Tenant and row isolation

- A query on tenant-owned data missing the tenant or owner predicate, or with
  it in one branch only; a join, subquery, count, export or search index that
  drops it [cross-tenant read]. Expect scoping in the base query or a default
  scope, not in the controller.
- RLS: a table with tenant data created without `ENABLE ROW LEVEL SECURITY`;
  the app connecting as the table owner without `FORCE ROW LEVEL SECURITY`, or
  as a superuser or `BYPASSRLS` role; a policy with `USING` but a missing or
  looser `WITH CHECK`; `USING (true)`; a permissive policy that ORs with a
  restrictive intent [isolation silently off].
- A view or `SECURITY DEFINER` function over RLS tables without
  `security_invoker = true` or a fixed `search_path` [runs as owner, bypasses
  RLS; search_path hijack].
- Tenant context set per session (`SET app.tenant_id`) on a pooled connection
  without `SET LOCAL` or a reset [next request inherits the tenant].
- Supabase or Firebase: a table or collection exposed to the anon key with no
  policy, or rules of `allow read, write: if true` [the public internet].

### Migrations that lock

Attacker-free: the gain is an outage. Postgres takes `ACCESS EXCLUSIVE` unless
noted, and a queued lock blocks every later read.

- `CREATE INDEX` without `CONCURRENTLY` on a live table; `CONCURRENTLY` inside a
  transaction (it fails) [writes blocked for the build].
- `ALTER COLUMN ... TYPE` (rewrites table and indexes); `ADD COLUMN` with a
  volatile default, identity or stored generated column (rewrite); `SET NOT
  NULL` without a validated `CHECK (col IS NOT NULL)` first (full scan); `ADD
  FOREIGN KEY` or `CHECK` without `NOT VALID` then `VALIDATE` [table locked].
- No `lock_timeout` on a DDL migration against a hot table [lock queue stalls
  all traffic].
- A rename or drop of a column the running code still reads, in the same
  deploy [errors until the new code is out]. Expect expand, migrate, contract
  across deploys.
- A backfill as one `UPDATE` over the whole table in the migration [long lock,
  WAL spike]; see `blockers.md` for the filter.

### Data exposure

- A query or serializer that returns whole rows (`SELECT *`, `toJSON` of the
  entity) to a client, now including a new `password_hash`, token, secret or
  PII column [leak to every caller].
- PII or secrets stored in plaintext where the codebase encrypts or hashes
  peers; a new column logged by query logging [leak via logs and dumps].
- A dump, seed or fixture with real customer data; a backup written to a
  public bucket, world-readable path or the Nix store [bulk leak].
- A connection string with a password in config, a URL or a log line; `sslmode`
  disabled or `rejectUnauthorized: false` to a remote database; a DB port
  bound to `0.0.0.0` or opened in a firewall [credential leak, MITM, exposure].

## Grep, on the diff

Run all five in one turn. Each matches added lines only (`^\+`), so line
numbers stay those of `diff`. A hit is a lead: read the hunk.

```sh
rg -n -i '^\+.*\b(select|insert|update|delete|where|order by)\b.*(\$\{|" *\+|\+ *"|%s|\.format\(|f"|f'\'')' "$D/diff"
rg -n '^\+.*(Unsafe\(|\.raw\(|whereRaw|orderByRaw|\.extra\(|RawSQL|literal\(|createNativeQuery|nativeQuery|\$where|\$function|mapReduce|\$regex)' "$D/diff"
rg -n '^\+.*(\.(create|update|insert|save|fill|upsert|findOneAndUpdate|updateOne|find|findOne)\((req|request)\.(body|query|params|data|all)|permit!|__all__|\*\*request\.(data|POST|json))' "$D/diff"
rg -n -i '^\+.*(create (unique )?index|alter column .* type|set not null|add (constraint .*)?foreign key|row level security|security definer|bypassrls|policy .* using \(true\)|drop column|rename column)' "$D/diff"
rg -n -i '^\+.*(postgres(ql)?://|mysql://|mongodb(\+srv)?://|redis://|sslmode=disable|rejectUnauthorized:\s*false|0\.0\.0\.0:(5432|3306|27017|6379))' "$D/diff"
```

## Sources

- https://cheatsheetseries.owasp.org/ (SQL Injection Prevention, Mass
  Assignment, Multi Tenant Security)
- https://owasp.org/API-Security/editions/2023/en/0xa3-broken-object-property-level-authorization/
- https://www.postgresql.org/docs/current/ddl-rowsecurity.html
- https://www.postgresql.org/docs/current/sql-altertable.html
- https://github.com/ankane/strong_migrations
- https://supabase.com/docs/guides/database/postgres/row-level-security
