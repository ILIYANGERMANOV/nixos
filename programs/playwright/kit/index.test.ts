import { fc, test } from "@fast-check/vitest";
import { describe, expect } from "vitest";
import { redact } from "./index.js";

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
  .filter((text) => !/bearer/i.test(text));

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
      token.map((t) => `Bearer ${t}`),
    ),
  ])("is idempotent, so a line redacted twice reads the same", (text) => {
    const once = redact(text);

    expect(redact(once)).toBe(once);
  });

  test("keeps the header name of a redacted line", () => {
    expect(redact("Authorization: Bearer abc")).toBe(
      "Authorization: Bearer [redacted]",
    );
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
