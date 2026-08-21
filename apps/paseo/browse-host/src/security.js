// SPDX-License-Identifier: MIT
"use strict";
// URL policy for the Paseo server-side browse host — deliberately PROPORTIONATE:
// this is an owner-only tool on the owner's own box.
//
// This is an OWNER-ONLY tool on the owner's own dev LXC. Browsing one's own
// localhost / RFC1918 / tailnet dev servers (e.g. dev-box:7700, localhost:3000)
// is the PRIMARY use case — both for the user's live panel and for the agent
// ("check my app at localhost:3000"). The owner already reaches these from the
// box's shell, and the agent already has shell access, so blocking them in the
// browser is friction, not security. We therefore ALLOW loopback, RFC1918,
// CGNAT/tailnet (v4 100.64/10, v6 ULA), and public.
//
// We STILL block the genuinely dangerous / useless: the cloud-metadata &
// link-local IPv4 range (169.254/16, incl. 169.254.169.254), multicast, reserved,
// the unspecified address, and non-http(s) schemes. IPv6 link-local (fe80::) is
// treated as noise: multi-homed hosts (dev-box) legitimately resolve to fe80::
// alongside real addresses, so it must NOT block the whole hostname.
//
// (v1 earlier required EVERY resolved address to be public — that broke the core
// use case; relaxed 2026-07-21 after live iPad testing hit dev-box:7700 denied.)

const dns = require("node:dns").promises;
const net = require("node:net");

class BrowserDenied extends Error {
  constructor(message) {
    super(message);
    this.name = "BrowserDenied";
    this.code = "browser_denied";
  }
}

// Parse "a.b.c.d" -> 32-bit int, or null if not IPv4.
function ipv4ToInt(ip) {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let value = 0;
  for (const part of parts) {
    const n = Number(part);
    if (!Number.isInteger(n) || n < 0 || n > 255) return null;
    value = value * 256 + n;
  }
  return value >>> 0;
}

function inV4Cidr(ipInt, baseIp, prefix) {
  const base = ipv4ToInt(baseIp);
  if (base === null || ipInt === null) return false;
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  return (ipInt & mask) === (base & mask);
}

// IPv4 ranges we refuse even for the owner's tool: cloud-metadata/link-local,
// multicast, reserved, "this host". Everything else (loopback, RFC1918, CGNAT/
// tailnet, public) is allowed on purpose.
const V4_DANGEROUS = [
  ["0.0.0.0", 8], // "this host" / invalid source
  ["169.254.0.0", 16], // link-local incl. 169.254.169.254 cloud metadata
  ["224.0.0.0", 4], // multicast
  ["240.0.0.0", 4], // reserved
];

function isDangerousIpv4(ip) {
  const ipInt = ipv4ToInt(ip);
  if (ipInt === null) return true; // unparseable → refuse
  for (const [base, prefix] of V4_DANGEROUS) {
    if (inV4Cidr(ipInt, base, prefix)) return true;
  }
  return false;
}

function isDangerousIpv6(ip) {
  const lower = ip.toLowerCase();
  // Normalize IPv4-mapped (::ffff:1.2.3.4) to the v4 check.
  const mapped = lower.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return isDangerousIpv4(mapped[1]);
  if (lower === "::") return true; // unspecified
  if (lower.startsWith("ff")) return true; // multicast
  // ::1 loopback, fe80:: link-local (noise), fc/fd ULA (tailnet), public: allowed.
  return false;
}

// True only for addresses we refuse even on an owner-only tool.
function isDangerousIp(ip) {
  if (net.isIPv4(ip)) return isDangerousIpv4(ip);
  if (net.isIPv6(ip)) return isDangerousIpv6(ip);
  return true; // unknown format → refuse
}

// Throws BrowserDenied unless the URL is http/https to a hostname that does not
// resolve to a dangerous (metadata/link-local/multicast) address. Loopback,
// RFC1918 and tailnet are allowed on purpose. Returns the parsed URL on success.
async function assertUrlAllowed(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new BrowserDenied(`Invalid URL: ${rawUrl}`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new BrowserDenied(`Blocked non-http(s) URL scheme: ${url.protocol}`);
  }
  const host = url.hostname;
  // Literal IP: classify directly (no DNS).
  if (net.isIP(host)) {
    if (isDangerousIp(host)) {
      throw new BrowserDenied(`Blocked navigation to ${host} (metadata/link-local/reserved)`);
    }
    return url;
  }
  // Hostname: resolve all A/AAAA; block only if it maps to a dangerous address
  // (e.g. a name pointing at 169.254.169.254). fe80:: noise is not dangerous.
  let addrs;
  try {
    addrs = await dns.lookup(host, { all: true });
  } catch (err) {
    throw new BrowserDenied(`DNS resolution failed for ${host}: ${err.message}`);
  }
  if (addrs.length === 0) {
    throw new BrowserDenied(`No addresses resolved for ${host}`);
  }
  for (const { address } of addrs) {
    if (isDangerousIp(address)) {
      throw new BrowserDenied(`Blocked ${host} -> ${address} (metadata/link-local/reserved)`);
    }
  }
  return url;
}

// Route-guard predicate: should this sub-request URL be aborted? Only aborts
// literal dangerous-IP URLs (cheap, synchronous) — a page (public or internal)
// must not pull the cloud-metadata endpoint. Loopback/RFC1918/tailnet sub-
// requests are allowed so internal pages load their own resources.
function shouldAbortSubRequest(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    return false;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    // data:, blob:, about: etc. are page-internal; let the browser handle them.
    return false;
  }
  const host = url.hostname;
  if (net.isIP(host)) return isDangerousIp(host);
  return false;
}

module.exports = {
  BrowserDenied,
  assertUrlAllowed,
  shouldAbortSubRequest,
  isDangerousIp,
};
