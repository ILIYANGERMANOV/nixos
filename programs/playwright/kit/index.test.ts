import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fc, test } from "@fast-check/vitest";
import { afterEach, beforeEach, describe, expect } from "vitest";
import { readSession, redact, SESSION_FILE } from "./index.js";

const BASE64URL =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

const token = fc.string({
  unit: fc.constantFrom(...BASE64URL),
  minLength: 16,
  maxLength: 48,
});

const queryParameter = fc.constantFrom(
  "access_token",
  "id_token",
  "refresh_token",
  "token",
  "code",
  "api_key",
  "api-key",
  "apikey",
  "key",
  "secret",
  "password",
  "signature",
);

const credentialLine = fc.constantFrom(
  (t: string) => `Authorization: Bearer ${t}`,
  (t: string) => `authorization=Basic ${t}`,
  (t: string) => `{"authorization":"Bearer ${t}"}`,
  (t: string) => `fetch failed with bearer ${t}`,
  (t: string) => `Cookie: sid=${t}; theme=dark`,
  (t: string) => `set-cookie: sid=${t}; Path=/; HttpOnly`,
);

const plainText = fc
  .stringMatching(/^[a-zA-Z0-9 .,]*$/)
  .filter((text) => !/bearer|eyJ/i.test(text));

describe("redact", () => {
  test.prop([credentialLine, token])(
    "removes the token from every credential line",
    (line, secret) => {
      expect(redact(line(secret))).not.toContain(secret);
    },
  );

  test.prop([queryParameter, fc.constantFrom("?", "&"), token])(
    "removes a credential query parameter and keeps the rest of the URL",
    (name, separator, secret) => {
      const url = `GET https://api.test/me${separator}${name}=${secret}#page=2`;

      expect(redact(url)).toBe(
        `GET https://api.test/me${separator}${name}=[redacted]#page=2`,
      );
    },
  );

  test.prop([token, token, token])(
    "removes a JWT anywhere in a line",
    (header, payload, signature) => {
      const jwt = `eyJ${header}.eyJ${payload}.${signature}`;

      expect(redact(`session ${jwt} expired`)).toBe(
        "session [redacted-jwt] expired",
      );
    },
  );

  test.prop([plainText])("leaves text with no credential alone", (text) => {
    expect(redact(text)).toBe(text);
  });

  test.prop([
    fc.oneof(
      fc.string(),
      fc.tuple(credentialLine, token).map(([line, secret]) => line(secret)),
    ),
  ])("is idempotent, so a line redacted twice reads the same", (text) => {
    const once = redact(text);

    expect(redact(once)).toBe(once);
  });

  test("keeps the scheme of a redacted Authorization header", () => {
    expect(redact("Authorization: Bearer abc")).toBe(
      "Authorization: Bearer [redacted]",
    );
  });

  test("keeps the name of a redacted Cookie header", () => {
    expect(redact("Cookie: sid=abc; theme=dark")).toBe("Cookie: [redacted]");
  });

  test("redacts every line of a multi-line text", () => {
    const text = "bearer aaaaaaaa\nordinary line\nCookie: sid=bbbbbbbb";

    expect(redact(text)).toBe(
      "Bearer [redacted]\nordinary line\nCookie: [redacted]",
    );
  });

  test("turns a value that is not a string into text", () => {
    expect(redact(undefined)).toBe("undefined");
  });
});

describe("readSession", () => {
  let runDir: string;

  beforeEach(() => {
    runDir = fs.mkdtempSync(path.join(os.tmpdir(), "qa-kit-"));
  });

  afterEach(() => {
    fs.rmSync(runDir, { recursive: true });
  });

  const writeSessionFile = (content: string) =>
    fs.writeFileSync(path.join(runDir, SESSION_FILE), content);

  test("reads what the session wrote", () => {
    const session = { endpoint: "http://127.0.0.1:9222", pid: 42 };

    writeSessionFile(JSON.stringify(session));

    expect(readSession(runDir)).toEqual(session);
  });

  test("gives null for a run without a session file", () => {
    expect(readSession(runDir)).toBeNull();
  });

  test.each([
    ["truncated JSON", '{"endpoint":"http://127'],
    ["JSON null", "null"],
    ["no pid", '{"endpoint":"http://127.0.0.1:9222"}'],
  ])("throws on %s", (_name, content) => {
    writeSessionFile(content);

    expect(() => readSession(runDir)).toThrow(/cannot read/);
  });
});
