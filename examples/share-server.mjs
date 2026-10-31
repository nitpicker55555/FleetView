#!/usr/bin/env node
/**
 * A share service for FleetView: where "share" publishes a conversation so anyone with the link can
 * read it. FleetView's own server is for your LAN; this one is meant to sit somewhere public.
 *
 *   SHARE_TOKEN=$(openssl rand -hex 24) PUBLIC_ORIGIN=https://share.example.com node share-server.mjs
 *
 * Then in FleetView → 分享设置… (Share Settings…): the address it is reachable at, and the token.
 * Node 18+, no dependencies. Pages are kept as files in SHARE_DIR (default ./shares).
 *
 *   POST   /api/shares        Authorization: Bearer <token>, JSON {title, html} → {id, url}
 *   DELETE /api/shares/<id>   Authorization: Bearer <token> → {ok}
 *   GET    /s/<id>            the page
 *
 * Put it behind HTTPS (a reverse proxy, a tunnel) before giving it a public address: the token
 * travels in a header.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";

const PORT = Number(process.env.PORT || 8790);
const TOKEN = process.env.SHARE_TOKEN || "";
const DIR = path.resolve(process.env.SHARE_DIR || "shares");
const ORIGIN = (process.env.PUBLIC_ORIGIN || `http://localhost:${PORT}`).replace(/\/+$/, "");
const LIMIT = 20 << 20;   // a long conversation is a few MB

if (!TOKEN) {
  console.error("set SHARE_TOKEN — it is what keeps strangers from publishing under your address");
  process.exit(1);
}
fs.mkdirSync(DIR, { recursive: true });

/**
 * The page was built from an agent's transcript — arbitrary text. FleetView escapes it before it
 * renders, and the page carries no script; this header makes sure none could run even if one
 * slipped through, and keeps the page out of search engines and other people's frames.
 */
const PAGE_HEADERS = {
  "Content-Type": "text/html; charset=utf-8",
  "Content-Security-Policy":
    "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; " +
    "form-action 'none'; frame-ancestors 'none'",
  "X-Robots-Tag": "noindex, nofollow",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
  "Cache-Control": "no-store",   // a withdrawn page must stop answering at once
};

const json = (res, code, obj) => {
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify(obj));
};

function authorized(req) {
  const m = String(req.headers.authorization || "").match(/^Bearer\s+(.+)$/);
  if (!m) return false;
  const given = Buffer.from(m[1].trim()), want = Buffer.from(TOKEN);
  return given.length === want.length && crypto.timingSafeEqual(given, want);
}

// Ids are 72 random bits, base64url: the link is the only key to the page, so it must not be guessable.
const validId = (id) => /^[A-Za-z0-9_-]{12}$/.test(id);
const file = (id) => path.join(DIR, id + ".html");

async function body(req) {
  const chunks = [];
  let size = 0;
  for await (const c of req) {
    size += c.length;
    if (size > LIMIT) throw Object.assign(new Error("too large"), { status: 413 });
    chunks.push(c);
  }
  return Buffer.concat(chunks).toString("utf8");
}

http.createServer(async (req, res) => {
  const p = new URL(req.url, "http://x").pathname;
  try {
    if (req.method === "GET" && p.startsWith("/s/")) {
      const id = p.slice(3);
      if (!validId(id) || !fs.existsSync(file(id))) return json(res, 404, { error: "no such page" });
      res.writeHead(200, PAGE_HEADERS);
      return fs.createReadStream(file(id)).pipe(res);
    }
    if (p === "/api/shares" || p.startsWith("/api/shares/")) {
      if (!authorized(req)) return json(res, 401, { error: "wrong token" });
      if (req.method === "POST" && p === "/api/shares") {
        let b;
        try { b = JSON.parse(await body(req)); }
        catch (e) { return json(res, e.status || 400, { error: e.status ? "too large" : "not JSON" }); }
        if (typeof b.html !== "string" || !b.html) return json(res, 400, { error: "no html" });
        const id = crypto.randomBytes(9).toString("base64url");
        fs.writeFileSync(file(id), b.html);
        console.log(new Date().toISOString(), "shared", id, String(b.title || "").slice(0, 80));
        return json(res, 200, { id, url: `${ORIGIN}/s/${id}` });
      }
      if (req.method === "DELETE") {
        const id = p.slice("/api/shares/".length);
        if (!validId(id) || !fs.existsSync(file(id))) return json(res, 404, { error: "no such page" });
        fs.unlinkSync(file(id));
        console.log(new Date().toISOString(), "withdrew", id);
        return json(res, 200, { ok: true });
      }
      return json(res, 405, { error: "not supported" });
    }
    if (p === "/healthz") return json(res, 200, { ok: true });
    return json(res, 404, { error: "not found" });
  } catch (e) {
    console.error(e);
    return json(res, 500, { error: "server error" });
  }
}).listen(PORT, () => console.log(`FleetView share service on :${PORT}, pages in ${DIR}, links at ${ORIGIN}/s/…`));
