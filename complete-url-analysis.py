#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────────
# comprehensive_url_analysis.py — Recon + Passive Security + Playwright capture
# ──────────────────────────────────────────────────────────────────────────────
"""
Purpose
-------
All‑in‑one URL auditor combining:
  • DNS / WHOIS / RDAP / TLS / HTTP header probe
  • Passive security posture (security headers, cookies, methods, mixed content,
    sensitive files, SPF/DMARC baseline)
  • Technology fingerprint (optional Wappalyzer CLI)
  • WordPress passive checks (no brute‑force; low‑impact GET/HEAD/OPTIONS)
  • Company/operator fingerprinting:
      - Crawl common legal pages (about/terms/privacy/contact)
      - Extract names, addresses, emails/phones, corporate IDs (CVR, UEN, etc.),
        ICP/备案号, VAT, payment fingerprints (USDT/crypto/IBAN)
      - Pull Cloudflare trace if present (/cdn-cgi/trace)
      - Fetch robots.txt/sitemap.xml/security.txt summaries
      - Query Certificate Transparency via crt.sh (no key needed) for subdomains
  • Optional Playwright capture: HAR, screenshots, PDF, cookies/storage, axe audit

Ethics & Scope
--------------
Only passive techniques. Respect terms of service and law. No authentication or
intrusive probing. The goal is documentation and triage, not exploitation.

Exit codes
----------
0 success, 1 usage/input, 2 network/timeout, 3 dependency/tool error, 4 unexpected.
"""

from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
import json
import os
import re
import socket
import ssl
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import urljoin, urlparse, urlsplit, parse_qs

# ──────────────────────────────────────────────────────────────────────────────
# Lazy imports (keep hard deps minimal; degrade gracefully)
# ──────────────────────────────────────────────────────────────────────────────

def _lazy_imports() -> Dict[str, Any]:
  mods: Dict[str, Any] = {}
  try:
    import requests  # type: ignore
    mods["requests"] = requests
  except Exception:
    mods["requests"] = None
  try:
    import dns.resolver  # type: ignore
    mods["dnsresolver"] = dns.resolver
  except Exception:
    mods["dnsresolver"] = None
  try:
    import whois as pywhois  # type: ignore  # python-whois
    mods["pywhois"] = pywhois
  except Exception:
    mods["pywhois"] = None
  try:
    import tldextract  # type: ignore
    mods["tldextract"] = tldextract
  except Exception:
    mods["tldextract"] = None
  try:
    from bs4 import BeautifulSoup  # type: ignore
    mods["bs4"] = BeautifulSoup
  except Exception:
    mods["bs4"] = None
  try:
    from playwright.sync_api import sync_playwright  # type: ignore
    mods["pw_sync"] = sync_playwright
  except Exception:
    mods["pw_sync"] = None
  return mods

# ──────────────────────────────────────────────────────────────────────────────
# Small utilities
# ──────────────────────────────────────────────────────────────────────────────

def _utc_iso_now() -> str:
  return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def normalize_url(raw: str) -> str:
  raw = raw.strip()
  if not re.match(r"^[a-zA-Z][a-zA-Z0-9+\-.]*://", raw):
    return "https://" + raw
  return raw


def is_ip(host: str) -> bool:
  try:
    ipaddress.ip_address(host)
    return True
  except ValueError:
    return False


def parse_domain(host: str, mods: Dict[str, Any]) -> Dict[str, Any]:
  out = {"input": host, "subdomain": None, "registered_domain": None, "suffix": None}
  if is_ip(host):
    return out
  tldextract = mods.get("tldextract")
  if tldextract is None:
    parts = host.split(".")
    if len(parts) >= 2:
      out["registered_domain"] = ".".join(parts[-2:])
      out["subdomain"] = ".".join(parts[:-2]) or None
      out["suffix"] = parts[-1]
    else:
      out["registered_domain"] = host
    return out
  ext = tldextract.extract(host)
  out["subdomain"] = ext.subdomain or None
  out["registered_domain"] = (
    f"{ext.domain}.{ext.suffix}" if ext.domain and ext.suffix else (ext.domain or host)
  )
  out["suffix"] = ext.suffix or None
  return out

# ──────────────────────────────────────────────────────────────────────────────
# DNS / WHOIS / RDAP
# ──────────────────────────────────────────────────────────────────────────────

def dns_query(name: str, rtype: str, mods: Dict[str, Any], timeout: float) -> List[str]:
  dnsresolver = mods.get("dnsresolver")
  if dnsresolver is None:
    return []
  try:
    resolver = dnsresolver.Resolver()
    resolver.lifetime = timeout
    ans = resolver.resolve(name, rtype, lifetime=timeout)
    return [str(r.to_text()) for r in ans]
  except Exception:
    return []


def dns_block(domain: str, mods: Dict[str, Any], timeout: float) -> Dict[str, Any]:
  out: Dict[str, Any] = {}
  for rtype in ["A", "AAAA", "CNAME", "NS", "MX", "TXT", "SOA"]:
    vals = dns_query(domain, rtype, mods, timeout)
    if vals:
      out[rtype] = vals
  return out


def run_system_whois(target: str, timeout: float) -> Optional[str]:
  from shutil import which
  exe = which("whois")
  if not exe:
    return None
  try:
    cp = subprocess.run([exe, target], capture_output=True, text=True, timeout=timeout)
    if cp.returncode == 0 and cp.stdout.strip():
      return cp.stdout
  except Exception:
    return None
  return None


def whois_domain(domain: str, mods: Dict[str, Any], timeout: float) -> Dict[str, Any]:
  result: Dict[str, Any] = {"source": None, "raw_text": None, "fields": {}}
  if is_ip(domain):
    return result
  pywhois = mods.get("pywhois")
  if pywhois is not None:
    try:
      data = pywhois.whois(domain)
      def _fmt(v):
        if isinstance(v, (list, tuple)):
          return [_fmt(x) for x in v]
        if isinstance(v, dt.datetime):
          return v.isoformat() if v.tzinfo else v.replace(tzinfo=dt.timezone.utc).isoformat()
        return v
      result["source"] = "python-whois"
      result["fields"] = {k: _fmt(v) for k, v in (data or {}).items()}
      return result
    except Exception:
      pass
  txt = run_system_whois(domain, timeout)
  if txt:
    result["source"] = "whois(1)"
    result["raw_text"] = txt
    fields: Dict[str, Any] = {}
    for key in [
      "Domain Name","Registry Domain ID","Registrar","Registrar IANA ID","Registrar URL",
      "Updated Date","Creation Date","Registry Expiry Date","Registrar Abuse Contact Email",
      "Registrar Abuse Contact Phone","Domain Status","Name Server","DNSSEC","Registrant Organization",
      "Registrant Country","Admin Email","Tech Email",
    ]:
      m = re.findall(rf"^{re.escape(key)}:\s*(.+)$", txt, flags=re.I|re.M)
      if m:
        fields[key] = m if len(m) > 1 else m[0]
    result["fields"] = fields
  return result


def rdap_get(url: str, mods: Dict[str, Any], timeout: float) -> Optional[Dict[str, Any]]:
  requests = mods.get("requests")
  if not requests:
    return None
  try:
    r = requests.get(url, timeout=timeout, headers={"Accept": "application/rdap+json"})
    if r.ok:
      return r.json()
  except Exception:
    return None
  return None

# ──────────────────────────────────────────────────────────────────────────────
# HTTP / TLS probe
# ──────────────────────────────────────────────────────────────────────────────

def http_probe(url: str, mods: Dict[str, Any], timeout: float, ua: str) -> Dict[str, Any]:
  out: Dict[str, Any] = {"request_url": url, "final_url": None, "status_code": None, "headers": None}
  requests = mods.get("requests")
  if not requests:
    return out
  try:
    h = {"User-Agent": ua, "Accept": "*/*"}
    resp = requests.head(url, allow_redirects=True, timeout=timeout, headers=h)
    if resp.status_code in (405, 400, 500) or not resp.headers:
      resp = requests.get(url, allow_redirects=True, timeout=timeout, headers=h, stream=True)
    out["final_url"] = str(resp.url)
    out["status_code"] = int(resp.status_code)
    out["headers"] = {k: v for k, v in resp.headers.items()}
    # Raw Set-Cookie list
    try:
      raw = []
      if hasattr(resp.raw, "headers") and hasattr(resp.raw.headers, "get_all"):
        raw = resp.raw.headers.get_all("Set-Cookie") or []
      elif hasattr(resp.raw, "headers") and hasattr(resp.raw.headers, "getlist"):
        raw = resp.raw.headers.getlist("Set-Cookie") or []
      out["set_cookie_list"] = raw
    except Exception:
      out["set_cookie_list"] = None
  except Exception as e:
    out["error"] = str(e)
  return out


def fetch_html(url: str, mods: Dict[str, Any], timeout: float, ua: str, max_bytes: int=512_000) -> Dict[str, Any]:
  requests = mods.get("requests")
  out = {"url": url, "status_code": None, "content_type": None, "length": None, "text": None, "error": None}
  if not requests:
    return out
  try:
    h = {"User-Agent": ua, "Accept": "text/html;q=1,*/*;q=0.5"}
    r = requests.get(url, timeout=timeout, headers=h, allow_redirects=True, stream=True)
    out["status_code"] = r.status_code
    out["content_type"] = r.headers.get("Content-Type", "")
    if "text/html" in (out["content_type"] or "").lower() and r.status_code < 400:
      buf = bytearray()
      for chunk in r.iter_content(chunk_size=8192):
        if chunk:
          if len(buf) + len(chunk) > max_bytes:
            buf.extend(chunk[: max_bytes - len(buf)])
            break
          buf.extend(chunk)
      out["length"] = len(buf)
      enc = r.encoding or "utf-8"
      try:
        out["text"] = buf.decode(enc, errors="replace")
      except Exception:
        out["text"] = buf.decode("utf-8", errors="replace")
  except Exception as e:
    out["error"] = str(e)
  return out


def tls_probe(host: str, port: int, timeout: float) -> Dict[str, Any]:
  out: Dict[str, Any] = {"host": host, "port": port, "cert": None, "protocol": None,
                         "cipher": None, "days_until_expiry": None}
  server_hostname = None if is_ip(host) else host
  try:
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=timeout) as sock:
      with ctx.wrap_socket(sock, server_hostname=server_hostname) as ss:
        cert = ss.getpeercert()
        out["protocol"] = ss.version()
        out["cipher"] = ss.cipher()
        try:
          ocsp = getattr(ss, "ocsp_response", None)
          out["ocsp_stapled"] = bool(ocsp) if ocsp is not None else None
        except Exception:
          out["ocsp_stapled"] = None
        def _ntd(tups: Iterable[Tuple[str, str]]):
          d: Dict[str, str] = {}
          for t in tups:
            if isinstance(t, tuple) and len(t) > 0 and isinstance(t[0], tuple):
              for k, v in t:
                d[k] = v
          return d
        subject = _ntd(cert.get("subject", ()))
        issuer = _ntd(cert.get("issuer", ()))
        san = cert.get("subjectAltName", ())
        nb = cert.get("notBefore"); na = cert.get("notAfter")
        days_left = None
        if na:
          try:
            exp = dt.datetime.strptime(na, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
            days_left = (exp - dt.datetime.now(dt.timezone.utc)).days
          except Exception:
            days_left = None
        out["cert"] = {
          "subject": subject or None,
          "issuer": issuer or None,
          "subjectAltName": [list(x) for x in san] if san else None,
          "notBefore": nb,
          "notAfter": na,
          "version": cert.get("version"),
          "serialNumber": cert.get("serialNumber"),
        }
        out["days_until_expiry"] = days_left
  except Exception as e:
    out["error"] = str(e)
  return out

# ──────────────────────────────────────────────────────────────────────────────
# Security headers / cookies / methods / mixed content / sensitive files
# ──────────────────────────────────────────────────────────────────────────────

def analyze_security_headers(headers: Dict[str, str], set_cookie_list: Optional[List[str]]=None) -> Dict[str, Any]:
  h = {k.lower(): v for k, v in (headers or {}).items()}
  missing: List[str] = []
  info: Dict[str, Any] = {}
  def present(name: str) -> bool: return name.lower() in h
  for c in [
    "strict-transport-security","content-security-policy","x-frame-options",
    "x-content-type-options","referrer-policy","permissions-policy",
    "cross-origin-opener-policy","cross-origin-resource-policy",
  ]:
    if not present(c): missing.append(c)
  if present("strict-transport-security"):
    val = h["strict-transport-security"]; info["hsts"] = val
    low = val.lower()
    if "max-age" not in low:
      missing.append("strict-transport-security:max-age")
    else:
      m = re.search(r"max-age\s*=\s*(\d+)", low)
      if m and int(m.group(1)) < 15552000:
        info["hsts_short_max_age"] = m.group(1)
    if "includesubdomains" not in low:
      info["hsts_note"] = "Consider includeSubDomains; preload requires it."
    if "preload" not in low:
      info["hsts_preload_hint"] = "Eligible for preload only with 'preload' and long max-age."
  if present("x-content-type-options") and h["x-content-type-options"].lower() != "nosniff":
    info["x_content_type_options_note"] = "Use 'nosniff'."
  csp = h.get("content-security-policy")
  if csp:
    bad = []
    low = csp.lower()
    if "unsafe-inline" in low or "unsafe-eval" in low: bad.append("uses 'unsafe-inline'/'unsafe-eval'")
    if re.search(r"(^|\s)default-src\s+[^;]*\*", low): bad.append("default-src allows '*'")
    if "http:" in low: bad.append("allows http: in CSP on HTTPS site")
    if "object-src" not in low: bad.append("missing object-src 'none'")
    if "frame-ancestors" not in low: bad.append("missing frame-ancestors")
    if bad: info["csp_findings"] = bad
  if not h.get("referrer-policy"):
    info["referrer_policy_note"] = "Missing Referrer-Policy (consider 'strict-origin-when-cross-origin' or stricter)."
  elif h.get("referrer-policy", "").strip().lower() in {"no-referrer-when-downgrade","unsafe-url"}:
    info["referrer_policy_note"] = f"Referrer-Policy is '{h['referrer-policy']}' (weaker than recommended)."
  if not h.get("permissions-policy"):
    info["permissions_policy_note"] = "Missing Permissions-Policy."
  cookies: List[Dict[str, Any]] = []
  raw_cookie_headers = set_cookie_list or ([] if "set-cookie" not in h else [h["set-cookie"]])
  for raw in raw_cookie_headers:
    for c in raw.split("\n"):
      c = c.strip(); if not c: continue
      flags = {
        "secure": "secure" in c.lower(),
        "httponly": "httponly" in c.lower(),
        "samesite": (re.search(r"samesite\s*=\s*(\w+)", c, re.I)),
      }
      cookies.append({
        "raw": c,
        "flags": {
          "secure": flags["secure"],
          "httponly": flags["httponly"],
          "samesite": flags["samesite"].group(1) if flags["samesite"] else None,
        },
      })
  return {"missing": missing, "notes": info, "cookies": cookies}


def allowed_methods(url: str, mods: Dict[str, Any], timeout: float, ua: str) -> Dict[str, Any]:
  r = probe_endpoint(url, mods, timeout, ua, method="OPTIONS")
  allow = None
  if r.get("status") and r.get("status") < 500:
    try:
      requests = mods.get("requests")
      if requests:
        resp = requests.options(url, timeout=timeout, headers={"User-Agent": ua})
        allow = resp.headers.get("Allow")
    except Exception:
      pass
  out = {"status": r.get("status"), "allow": allow}
  try:
    requests = mods.get("requests")
    if requests:
      tr = requests.request("TRACE", url, timeout=timeout, headers={"User-Agent": ua})
      out["trace_status"] = tr.status_code
  except Exception:
    out["trace_status"] = None
  return out


def find_mixed_content(base_url: str, html: Optional[str]) -> List[str]:
  if not html or not base_url.lower().startswith("https://"):
    return []
  bad: List[str] = []
  for m in re.finditer(r"(?:src|href)\s*=\s*['\"](http://[^'\"]+)['\"]", html, re.I):
    bad.append(m.group(1))
  return sorted(list(set(bad)))[:50]


def probe_endpoint(url: str, mods: Dict[str, Any], timeout: float, ua: str, method: str="HEAD") -> Dict[str, Any]:
  requests = mods.get("requests"); out = {"url": url, "status": None, "length": None, "note": None, "error": None}
  if not requests: return out
  try:
    h = {"User-Agent": ua, "Accept": "*/*"}
    if method == "HEAD": r = requests.head(url, timeout=timeout, headers=h, allow_redirects=True)
    elif method == "GET": r = requests.get(url, timeout=timeout, headers=h, allow_redirects=True)
    elif method == "OPTIONS": r = requests.options(url, timeout=timeout, headers=h, allow_redirects=True)
    else: r = requests.request(method, url, timeout=timeout, headers=h, allow_redirects=True)
    out["status"] = r.status_code
    out["length"] = int(r.headers.get("Content-Length", "0")) if r.headers.get("Content-Length") else None
    if method == "GET" and r.ok and "text/html" in r.headers.get("Content-Type", "").lower():
      text = r.text[:8192]
      if "Index of /" in text: out["note"] = "directory_indexing"
  except Exception as e:
    out["error"] = str(e)
  return out


def check_sensitive_files(url: str, mods: Dict[str, Any], timeout: float, ua: str) -> List[Dict[str, Any]]:
  candidates = [
    "/wp-config.php","/wp-config.php.bak","/wp-config.php~","/wp-config.zip","/wp-config.tar.gz",
    "/backup.zip","/backup.tar.gz","/database.sql","/.env","/.git/config","/.git/HEAD","/.gitignore",
    "/.svn/entries","/.DS_Store","/.user.ini","/phpinfo.php","/wp-config-sample.php","/wp-content/debug.log",
    "/.well-known/security.txt",
  ]
  out: List[Dict[str, Any]] = []
  for path in candidates:
    r = probe_endpoint(urljoin(url, path), mods, timeout, ua, method="HEAD")
    st = r.get("status")
    if st and st < 400:
      out.append({"path": path, "status": st, "note": "unexpectedly accessible"})
    elif st == 403:
      out.append({"path": path, "status": st, "note": "forbidden (OK)"})
  return out

# ──────────────────────────────────────────────────────────────────────────────
# WordPress passive detection
# ──────────────────────────────────────────────────────────────────────────────

_version_re = re.compile(r"^\d+(?:\.\d+){1,3}$")


def _parse_assets_for_wp_slugs(html: str) -> Dict[str, Any]:
  slugs = {"plugins": {}, "themes": {}, "core_version": None, "generator": None}
  gen = re.search(r'<meta[^>]+name=["\']generator["\'][^>]+content=["\']([^"\']+)["\']', html, re.I)
  if gen:
    slugs["generator"] = gen.group(1)
    m = re.search(r"WordPress\s+([\d\.]+)", slugs["generator"], re.I)
    if m: slugs["core_version"] = m.group(1)
  for m in re.finditer(r"(?:href|src)\s*=\s*['\"]([^'\"]+)['\"]", html, re.I):
    url = m.group(1); p = urlsplit(url)
    if "/wp-content/plugins/" in url:
      parts = p.path.split("/");
      try:
        idx = parts.index("plugins"); slug = parts[idx+1] if len(parts) > idx+1 else None
      except ValueError:
        slug = None
      if slug:
        ver = parse_qs(p.query).get("ver", [None])[0]
        slugs["plugins"].setdefault(slug, {"versions_seen": set()})
        if ver and _version_re.match(ver): slugs["plugins"][slug]["versions_seen"].add(ver)
    if "/wp-content/themes/" in url:
      parts = p.path.split("/");
      try:
        idx = parts.index("themes"); slug = parts[idx+1] if len(parts) > idx+1 else None
      except ValueError:
        slug = None
      if slug:
        ver = parse_qs(p.query).get("ver", [None])[0]
        slugs["themes"].setdefault(slug, {"versions_seen": set()})
        if ver and _version_re.match(ver): slugs["themes"][slug]["versions_seen"].add(ver)
    if "/wp-includes/" in url and "ver=" in url and not slugs["core_version"]:
      v = parse_qs(p.query).get("ver", [None])[0]
      if v and _version_re.match(v): slugs["core_version"] = v
  for d in (slugs["plugins"], slugs["themes"]):
    for k, v in d.items(): v["versions_seen"] = sorted(list(v["versions_seen"]))
  return slugs


def detect_wordpress(base_url: str, html: Optional[str], mods: Dict[str, Any], timeout: float, ua: str) -> Dict[str, Any]:
  out = {"detected": False, "core_version_hint": None, "generator": None, "plugins": {},
         "themes": {}, "endpoints": {}, "issues": []}
  if html:
    p = _parse_assets_for_wp_slugs(html)
    out.update({"generator": p["generator"], "core_version_hint": p["core_version"],
                "plugins": p["plugins"], "themes": p["themes"]})
    if p["core_version"] or "/wp-content/" in html or "/wp-includes/" in html or (
      p["generator"] and "wordpress" in p["generator"].lower()):
      out["detected"] = True
  for path, method in [("/wp-json/","GET"),("/readme.html","GET"),("/wp-login.php","HEAD"),
                       ("/wp-admin/admin-ajax.php","HEAD"),("/xmlrpc.php","GET"),("/wp-content/uploads/","GET")]:
    r = probe_endpoint(urljoin(base_url, path), mods, timeout, ua, method=method)
    out["endpoints"][path] = r
    if path == "/wp-json/" and r.get("status") in (200,401,403): out["detected"] = True
    if path == "/wp-admin/admin-ajax.php" and r.get("status") in (200,400,405): out["detected"] = True
    if path == "/readme.html" and r.get("status") == 200: out["issues"].append("WordPress readme.html is accessible (discloses version).")
    if path == "/xmlrpc.php" and r.get("status") in (200,405): out["issues"].append("xmlrpc.php is enabled (consider disabling or restricting).")
    if path == "/wp-content/uploads/" and r.get("note") == "directory_indexing": out["issues"].append("Directory indexing enabled under /wp-content/uploads/.")
  return out

# ──────────────────────────────────────────────────────────────────────────────
# Email posture (SPF/DMARC)
# ──────────────────────────────────────────────────────────────────────────────

def _parse_dmarc(txt: str) -> Dict[str, str]:
  parts: Dict[str, str] = {}
  for kv in txt.split(";"):
    kv = kv.strip();
    if not kv or "=" not in kv: continue
    k, v = kv.split("=", 1); parts[k.strip().lower()] = v.strip()
  return parts


def analyze_email_posture(domain: str, dns_records: Dict[str, Any], mods: Dict[str, Any], timeout: float) -> Dict[str, Any]:
  out = {"spf": None, "dmarc": None, "issues": []}
  spf_txt: List[str] = []
  for t in (dns_records or {}).get("TXT", []):
    if "v=spf1" in t.lower(): spf_txt.append(t.strip('"'))
  out["spf"] = spf_txt or None
  if len(spf_txt) > 1: out["issues"].append("Multiple SPF v=spf1 TXT records present (must be exactly one).")
  joined = " ".join(spf_txt); lookups = 0
  for token in re.findall(r"(?::|^|\s)(include:[^\s]+|a\b|mx\b|exists:[^\s]+|ptr\b|redirect=\S+)", joined, flags=re.I):
    kind = token.split(":")[0].split("=")[0].lower()
    if kind in {"include","a","mx","exists","ptr","redirect"}: lookups += 1
  if lookups > 10: out["issues"].append(f"SPF may exceed the 10-DNS-lookup limit (estimated {lookups}).")
  if not spf_txt:
    out["issues"].append("SPF record missing.")
  else:
    if any("+all" in s.lower() for s in spf_txt): out["issues"].append("SPF uses +all (permits everyone) — unsafe.")
    if " ptr" in (" " + joined.lower() + " "): out["issues"].append("SPF uses 'ptr' (deprecated).")
    if not any(("~all" in s.lower()) or ("-all" in s.lower()) for s in spf_txt): out["issues"].append("SPF lacks an explicit ~all or -all mechanism.")
  dmarc = dns_query(f"_dmarc.{domain}", "TXT", mods, timeout)
  if len(dmarc) > 1: out["issues"].append("Multiple DMARC TXT records present (must be exactly one).")
  if dmarc:
    txt = "; ".join([x.strip('"') for x in dmarc]); out["dmarc"] = txt
    d = _parse_dmarc(txt); out["dmarc_details"] = d
    pol = d.get("p", "").lower()
    if not pol: out["issues"].append("DMARC found but no policy 'p='.")
    elif pol == "none": out["issues"].append("DMARC p=none (monitor only). Consider 'quarantine' or 'reject'.")
    if d.get("adkim", "r").lower() != "s" or d.get("aspf", "r").lower() != "s": out["issues"].append("DMARC alignment relaxed (adkim/aspf != s).")
    if "rua" not in d: out["issues"].append("DMARC missing aggregate reporting (rua).")
  else:
    out["issues"].append("DMARC record missing (_dmarc).")
  return out

# ──────────────────────────────────────────────────────────────────────────────
# Company/operator fingerprinting (heuristics)
# ──────────────────────────────────────────────────────────────────────────────

LEGAL_SLUGS = [
  "about","about-us","aboutus","company","legal","terms","terms-of-service","terms-of-use",
  "tos","privacy","privacy-policy","policy","contact","contact-us","imprint","impressum",
]

COMPANY_PAT = re.compile(
  r"\b([A-Z][A-Za-z0-9&.,'()\- ]{2,}?)\s+(?:Ltd\.?|Limited|LLC|Inc\.?|Incorporated|GmbH|S\.?A\.?|S\.?r\.?l\.?|Pte\.?\s+Ltd\.?|BV|NV|OY|AB|ApS|A/S|SAS|Sp\.\s*z\.\s*o\.\s*o\.|S\.A\. de C\.V\.|PLC|LLP)\b",
  re.I)

EMAIL_PAT = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I)
PHONE_PAT = re.compile(r"\+?[0-9][0-9 .()\-]{6,}[0-9]")
CVR_PAT = re.compile(r"\bCVR\s*(?:nr\.|no\.|number)?\s*[:#]?\s*(\d{8})\b", re.I)
UEN_PAT = re.compile(r"\bUEN\s*[:#]?\s*([0-9A-Z]{9,10})\b", re.I)
VAT_PAT = re.compile(r"\bVAT\s*(?:No\.|Number)?\s*[:#]?\s*([A-Z]{2}[A-Z0-9]{2,12})\b", re.I)
ICP_PAT = re.compile(r"(ICP|备案|ICP备)\s*[:：]?\s*([A-Za-z0-9\-]{6,})")
ETH_PAT = re.compile(r"0x[a-fA-F0-9]{40}")
BTC_PAT = re.compile(r"\b[13][a-km-zA-HJ-NP-Z1-9]{25,34}\b")
TRX_PAT = re.compile(r"\bT[1-9A-HJ-NP-Za-km-z]{33}\b")
IBAN_PAT = re.compile(r"\b[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\b")
SOCIAL_PAT = re.compile(r"(t\.me/\w+|telegram\.me/\w+|wa\.me/\d+|whatsapp\.com/\w+|wechat|微信)", re.I)


def fetch_text(url: str, mods: Dict[str, Any], timeout: float, ua: str) -> Tuple[int, str, str]:
  requests = mods.get("requests")
  if not requests: return (0, "", "")
  try:
    r = requests.get(url, timeout=timeout, headers={"User-Agent": ua})
    return (r.status_code, r.headers.get("Content-Type", ""), r.text)
  except Exception:
    return (0, "", "")


def company_scan(base_url: str, html_text: Optional[str], mods: Dict[str, Any], timeout: float, ua: str) -> Dict[str, Any]:
  found_pages: Dict[str, Dict[str, Any]] = {}
  soup_texts: List[str] = []
  bs4 = mods.get("bs4")
  # Home page text
  if html_text and bs4:
    soup = bs4(html_text, "html.parser")
    soup_texts.append(soup.get_text(" ", strip=True))
  # Probe legal slugs
  for slug in LEGAL_SLUGS:
    u = urljoin(base_url if base_url.endswith('/') else base_url+'/', slug)
    code, ct, text = fetch_text(u, mods, timeout, ua)
    if code in (200, 206) and text:
      found_pages[slug] = {"url": u, "status": code, "length": len(text)}
      if bs4:
        soup_texts.append(mods["bs4"](text, "html.parser").get_text(" ", strip=True))
  # robots / sitemap / security.txt / cf trace
  robots = fetch_text(urljoin(base_url, "/robots.txt"), mods, timeout, ua)
  if robots[0] in (200, 206): found_pages["robots.txt"] = {"url": urljoin(base_url, "/robots.txt"), "status": robots[0]}
  sitemap = fetch_text(urljoin(base_url, "/sitemap.xml"), mods, timeout, ua)
  if sitemap[0] in (200, 206): found_pages["sitemap.xml"] = {"url": urljoin(base_url, "/sitemap.xml"), "status": sitemap[0]}
  sec = fetch_text(urljoin(base_url, "/.well-known/security.txt"), mods, timeout, ua)
  if sec[0] in (200, 206): found_pages["security.txt"] = {"url": urljoin(base_url, "/.well-known/security.txt"), "status": sec[0]}
  cftrace = fetch_text(urljoin(base_url, "/cdn-cgi/trace"), mods, timeout, ua)
  cf_trace_kv = {}
  if cftrace[0] in (200, 206) and cftrace[2]:
    for line in cftrace[2].splitlines():
      if "=" in line:
        k, v = line.split("=", 1); cf_trace_kv[k.strip()] = v.strip()
  # Aggregate text and extract patterns
  text_blob = "\n".join(soup_texts)[:500000]
  matches = {
    "company_names": sorted(set(m.group(0).strip()) for m in COMPANY_PAT.finditer(text_blob))[:25],
    "emails": sorted(set(e.lower() for e in EMAIL_PAT.findall(text_blob)))[:50],
    "phones": sorted(set(p.strip() for p in PHONE_PAT.findall(text_blob)))[:50],
    "cvr": sorted(set(CVR_PAT.findall(text_blob)))[:10],
    "uen": sorted(set(UEN_PAT.findall(text_blob)))[:10],
    "vat": sorted(set(VAT_PAT.findall(text_blob)))[:20],
    "icp": sorted(set(m.group(2) for m in ICP_PAT.finditer(text_blob)))[:10],
    "crypto": {
      "eth": sorted(set(ETH_PAT.findall(text_blob)))[:20],
      "btc": sorted(set(BTC_PAT.findall(text_blob)))[:20],
      "trx": sorted(set(TRX_PAT.findall(text_blob)))[:20],
    },
    "iban": sorted(set(IBAN_PAT.findall(text_blob)))[:20],
    "social": sorted(set(m.group(1) for m in SOCIAL_PAT.finditer(text_blob)))[:50],
  }
  return {"pages": found_pages, "cloudflare_trace": cf_trace_kv or None, "extractions": matches}

# ──────────────────────────────────────────────────────────────────────────────
# Certificate Transparency via crt.sh (no API key; best-effort)
# ──────────────────────────────────────────────────────────────────────────────

def crtsh_subdomains(domain: str, mods: Dict[str, Any], timeout: float, limit: int=100) -> Dict[str, Any]:
  requests = mods.get("requests")
  if not requests or is_ip(domain): return {"note": "unavailable"}
  try:
    q = f"https://crt.sh/?q=%25.{domain}&output=json"
    r = requests.get(q, timeout=timeout, headers={"User-Agent": "Mozilla/5.0"})
    if not r.ok: return {"error": f"HTTP {r.status_code}"}
    data = r.json()
    names: List[str] = []
    for row in data:
      val = row.get("name_value") or ""
      for nm in set(val.split("\n")):
        nm = nm.strip().lower()
        if nm.endswith("."+domain) or nm == domain or nm.endswith(domain):
          names.append(nm)
    uniq = sorted(set(names))
    if len(uniq) > limit: uniq = uniq[:limit]
    return {"count": len(uniq), "subdomains": uniq}
  except Exception as e:
    return {"error": str(e)}

# ──────────────────────────────────────────────────────────────────────────────
# Playwright capture (optional)
# ──────────────────────────────────────────────────────────────────────────────

def pw_capture(urls: List[str], outdir: Path, har: bool, screens: bool, pdf: bool, axe: bool,
               timeout_ms: int, ua: str, mods: Dict[str, Any]) -> Dict[str, Any]:
  sync_pw = mods.get("pw_sync")
  if not sync_pw:
    return {"error": "playwright not installed", "pages": []}
  outdir.mkdir(parents=True, exist_ok=True)
  art = outdir / "artifacts"; art.mkdir(exist_ok=True)
  screens_dir = art / "screens"; pdf_dir = art / "pdf"
  if screens: screens_dir.mkdir(exist_ok=True)
  if pdf: pdf_dir.mkdir(exist_ok=True)
  har_path = str(art / "session.har") if har else None
  results: Dict[str, Any] = {"artifacts_dir": str(art), "pages": [], "har": har_path, "errors": []}
  cookies_path = art / "cookies.json"; storage_path = art / "storage_state.json"
  try:
    with sync_pw() as p:
      browser = p.chromium.launch(headless=True)
      context = browser.new_context(
        record_har_path=har_path if har else None,
        record_har_mode="minimal" if har else None,
        user_agent=ua,
        ignore_https_errors=True,
      )
      for idx, u in enumerate(urls, 1):
        page = context.new_page()
        page.set_default_timeout(timeout_ms)
        page.goto(u, wait_until="load")
        axe_report = None
        if axe:
          try:
            page.add_script_tag(url="https://cdnjs.cloudflare.com/ajax/libs/axe-core/4.9.1/axe.min.js")
            axe_report = page.evaluate("async () => await axe.run()")
          except Exception as e:
            axe_report = {"error": str(e)}
        shot_path = None; pdf_path = None
        if screens:
          shot_path = screens_dir / f"page_{idx:02d}.png"
          page.screenshot(path=str(shot_path), full_page=True)
        if pdf:
          try:
            pdf_path = pdf_dir / f"page_{idx:02d}.pdf"
            page.pdf(path=str(pdf_path), print_background=True)
          except Exception as e:
            pdf_path = None; results["errors"].append(f"pdf page {idx}: {e}")
        results["pages"].append({
          "requested_url": u,
          "final_url": page.url,
          "screenshot": str(shot_path) if shot_path else None,
          "pdf": str(pdf_path) if pdf_path else None,
          "axe_report": axe_report if axe else None,
          "console": [],
        })
      # save cookies + storage
      try:
        cookies = context.cookies()
        storage = context.storage_state()
        cookies_path.write_text(json.dumps(cookies, indent=2, ensure_ascii=False))
        storage_path.write_text(json.dumps(storage, indent=2, ensure_ascii=False))
        results["cookies"] = str(cookies_path); results["storage_state"] = str(storage_path)
      except Exception:
        pass
      context.close(); browser.close()
  except Exception as e:
    results.setdefault("errors", []).append(str(e))
  return results

# ──────────────────────────────────────────────────────────────────────────────
# Wappalyzer CLI (optional)
# ──────────────────────────────────────────────────────────────────────────────

def run_wappalyzer(url: str, timeout: float) -> Optional[Dict[str, Any]]:
  from shutil import which
  exe = which("wappalyzer") or which("wappalyzer-cli")
  if not exe: return None
  try:
    cp = subprocess.run([exe, url, "-J", "-t", "30"], capture_output=True, text=True, timeout=timeout)
    if cp.returncode != 0 or not cp.stdout.strip():
      return {"error": f"exit {cp.returncode}", "stderr": cp.stderr[-500:]}
    last_obj = None
    for line in cp.stdout.splitlines():
      line = line.strip();
      if not line: continue
      try:
        last_obj = json.loads(line)
      except Exception:
        pass
    return last_obj
  except Exception as e:
    return {"error": str(e)}

# ──────────────────────────────────────────────────────────────────────────────
# Argument parser
# ──────────────────────────────────────────────────────────────────────────────

def build_arg_parser() -> argparse.ArgumentParser:
  epilog = r"""
Examples
--------
Basic
  comprehensive_url_analysis.py https://example.com

Save JSON + artifacts
  comprehensive_url_analysis.py example.com --out report.json --pw --pw-screens --pw-har

Lean (no Geo/Wappalyzer)
  comprehensive_url_analysis.py example.com --no-geo --no-wappalyzer

CT subdomains only
  comprehensive_url_analysis.py example.com --no-http --no-tls --crtsh-only

Playwright + axe
  comprehensive_url_analysis.py target.tld --pw --pw-axe --artifacts evidence_target
"""
  p = argparse.ArgumentParser(
    prog="comprehensive_url_analysis.py",
    description=(
      "Audit a URL: DNS/WHOIS/RDAP, HTTP/TLS, headers/cookies/methods, mixed content, "
      "SPF/DMARC, WordPress passive checks, operator fingerprinting, optional Wappalyzer "
      "and Playwright evidence capture."
    ),
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=epilog,
  )
  p.add_argument("url", help="Target URL or hostname (https assumed if missing).")
  p.add_argument("--out", metavar="FILE", help="Write JSON report to FILE.")
  p.add_argument("-T","--timeout", type=float, default=15.0, help="Network timeout (s).")
  p.add_argument("-A","--user-agent", default="comprehensive-url-analysis/3.0 (+local)", help="HTTP User-Agent.")

  # Feature toggles
  p.add_argument("--no-dns", action="store_true", help="Disable DNS record lookup.")
  p.add_argument("--no-whois", action="store_true", help="Disable WHOIS lookup.")
  p.add_argument("--no-rdap", action="store_true", help="Disable RDAP lookups.")
  p.add_argument("--no-http", action="store_true", help="Disable HTTP probe.")
  p.add_argument("--no-tls", action="store_true", help="Disable TLS probe.")
  p.add_argument("--no-geo", action="store_true", help="Disable IP geolocation.")
  p.add_argument("--no-wappalyzer", action="store_true", help="Disable Wappalyzer fingerprint.")
  p.add_argument("--no-vuln", action="store_true", help="Disable vulnerability checks layer.")
  p.add_argument("--no-company", action="store_true", help="Disable operator/company fingerprinting.")
  p.add_argument("--crtsh-only", action="store_true", help="Only run crt.sh subdomain enumeration (fast check).")

  # Playwright options
  p.add_argument("--pw", action="store_true", help="Enable Playwright capture (Chromium).")
  p.add_argument("--pw-har", action="store_true", help="Record HAR (minimal).")
  p.add_argument("--pw-screens", action="store_true", help="Take full-page screenshots.")
  p.add_argument("--pw-pdf", action="store_true", help="Print PDF of pages (Chromium-only; best-effort).")
  p.add_argument("--pw-axe", action="store_true", help="Run axe-core accessibility audit (inject from CDN).")
  p.add_argument("--pw-timeout-ms", type=int, default=20000, help="Per-page timeout in ms (default 20000).")
  p.add_argument("--artifacts", default=None, help="Artifacts directory (default: evidence_<host>).")

  return p

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def main(argv: Optional[List[str]] = None) -> int:
  args = build_arg_parser().parse_args(argv)
  mods = _lazy_imports()

  url = normalize_url(args.url)
  parsed = urlparse(url)
  if not parsed.hostname:
    print("ERROR: Could not extract hostname from input.", file=sys.stderr)
    return 1
  host = parsed.hostname

  report: Dict[str, Any] = {
    "target": {"input": args.url, "normalized_url": url, "host": host},
    "timestamps": {"started_utc": _utc_iso_now()},
    "modules": {
      "dns": not args.no_dns,
      "whois": not args.no_whois,
      "rdap": not args.no_rdap,
      "http": not args.no_http,
      "tls": not args.no_tls,
      "geo": not args.no_geo,
      "wappalyzer": not args.no_wappalyzer,
      "vuln": not args.no_vuln,
      "company": not args.no_company,
      "playwright": bool(args.pw),
      "crtsh": True,
    },
    "results": {},
    "errors": {},
  }

  # crt.sh fast path
  if args.crtsh_only:
    try:
      dom = parse_domain(host, mods).get("registered_domain") or host
      report["results"]["crtsh"] = crtsh_subdomains(dom, mods, args.timeout)
    except Exception as e:
      report["errors"]["crtsh"] = str(e)
    report["timestamps"]["finished_utc"] = _utc_iso_now()
    j = json.dumps(report, indent=2, ensure_ascii=False); print(j)
    if args.out:
      try:
        with open(args.out, "w", encoding="utf-8") as f: f.write(j)
      except Exception as e:
        print(f"WARNING: failed to write --out: {e}", file=sys.stderr)
    return 0

  # Domain parsing
  report["results"]["domain_parsing"] = parse_domain(host, mods)

  # DNS
  dns_records: Dict[str, Any] = {}
  if not args.no_dns and not is_ip(host):
    try:
      dom = report["results"]["domain_parsing"].get("registered_domain") or host
      dns_records = dns_block(dom, mods, args.timeout)
      report["results"]["dns"] = dns_records
    except Exception as e:
      report["errors"]["dns"] = str(e)

  # WHOIS / RDAP
  if not args.no_whois and not is_ip(host):
    try:
      dom = report["results"]["domain_parsing"].get("registered_domain") or host
      report["results"]["whois"] = whois_domain(dom, mods, args.timeout)
    except Exception as e:
      report["errors"]["whois"] = str(e)
  if not args.no_rdap and not is_ip(host):
    try:
      dom = report["results"]["domain_parsing"].get("registered_domain") or host
      report["results"]["rdap_domain"] = rdap_get(f"https://rdap.org/domain/{dom}", mods, args.timeout)
    except Exception as e:
      report["errors"]["rdap_domain"] = str(e)

  # Resolve IPs (best effort)
  ips: List[str] = []
  try:
    if dns_records.get("A"): ips.extend([x.split()[0] if " " in x else x for x in dns_records["A"]])
    if dns_records.get("AAAA"): ips.extend([x.split()[0] if " " in x else x for x in dns_records["AAAA"]])
    if not ips:
      infos = socket.getaddrinfo(host, None)
      for fam, _, _, _, sockaddr in infos:
        if fam == socket.AF_INET: ips.append(sockaddr[0])
        elif fam == socket.AF_INET6: ips.append(sockaddr[0])
    report["results"]["resolved_ips"] = sorted(list(set(ips)))
  except Exception as e:
    report["errors"]["resolve"] = str(e)

  # RDAP on first IP + Geo
  ip0 = ips[0] if ips else None
  if ip0:
    if not args.no_rdap:
      try:
        report["results"]["rdap_ip"] = rdap_get(f"https://rdap.org/ip/{ip0}", mods, args.timeout)
      except Exception as e:
        report["errors"]["rdap_ip"] = str(e)
    if not args.no_geo:
      try:
        requests = mods.get("requests")
        if requests:
          r = requests.get(
            f"http://ip-api.com/json/{ip0}?fields=status,country,countryCode,region,regionName,city,zip,lat,lon,isp,org,as,asname,reverse,proxy,hosting,query",
            timeout=args.timeout,
          )
          if r.ok: report["results"]["ip_geolocation"] = r.json()
      except Exception as e:
        report["errors"]["ip_geolocation"] = str(e)

  # HTTP
  http_info: Dict[str, Any] = {}
  if not args.no_http:
    try:
      http_info = http_probe(url, mods, args.timeout, args.user_agent)
      report["results"]["http"] = http_info
    except Exception as e:
      report["errors"]["http"] = str(e)

  # TLS
  if not args.no_tls:
    try:
      report["results"]["tls"] = tls_probe(host, 443, args.timeout)
    except Exception as e:
      report["errors"]["tls"] = str(e)

  # Wappalyzer
  if not args.no_wappalyzer:
    try:
      w = run_wappalyzer(url, timeout=max(10.0, args.timeout))
      report["results"]["wappalyzer"] = w
      if w is None:
        report["errors"]["wappalyzer"] = "Wappalyzer CLI not found; install with: npm i -g wappalyzer"
    except Exception as e:
      report["errors"]["wappalyzer"] = str(e)

  # Fetch page for content analysis
  page_html: Optional[str] = None
  if not args.no_http and not args.no_vuln:
    try:
      fin = (http_info.get("final_url") or url) if http_info else url
      fetched = fetch_html(fin, mods, args.timeout, args.user_agent, max_bytes=512_000)
      if fetched.get("text"): page_html = fetched["text"]
      report["results"]["page_snippet"] = {
        "url": fetched.get("url"), "status_code": fetched.get("status_code"),
        "content_type": fetched.get("content_type"), "length": fetched.get("length"),
      }
    except Exception as e:
      report["errors"]["fetch_html"] = str(e)

  # Vulnerability / posture
  if not args.no_vuln:
    vuln: Dict[str, Any] = {
      "security_headers": None, "http_methods": None, "mixed_content": None,
      "sensitive_files": None, "email_posture": None, "wordpress": None,
    }
    try:
      headers = (http_info or {}).get("headers") or {}
      sc_list = (http_info or {}).get("set_cookie_list")
      vuln["security_headers"] = analyze_security_headers(headers, sc_list)
    except Exception as e:
      report["errors"]["security_headers"] = str(e)
    try:
      fin = (http_info.get("final_url") or url) if http_info else url
      vuln["http_methods"] = allowed_methods(fin, mods, args.timeout, args.user_agent)
    except Exception as e:
      report["errors"]["http_methods"] = str(e)
    try:
      fin = (http_info.get("final_url") or url) if http_info else url
      vuln["mixed_content"] = find_mixed_content(fin, page_html)
    except Exception as e:
      report["errors"]["mixed_content"] = str(e)
    try:
      fin = (http_info.get("final_url") or url) if http_info else url
      vuln["sensitive_files"] = check_sensitive_files(fin, mods, args.timeout, args.user_agent)
    except Exception as e:
      report["errors"]["sensitive_files"] = str(e)
    try:
      dom = report["results"]["domain_parsing"].get("registered_domain") or host
      vuln["email_posture"] = analyze_email_posture(dom, dns_records, mods, args.timeout)
    except Exception as e:
      report["errors"]["email_posture"] = str(e)
    try:
      fin = (http_info.get("final_url") or url) if http_info else url
      vuln["wordpress"] = detect_wordpress(fin, page_html, mods, args.timeout, args.user_agent)
    except Exception as e:
      report["errors"]["wordpress"] = str(e)
    report["results"]["vulnerability_audit"] = vuln

  # Company/operator fingerprinting
  if not args.no_company:
    try:
      fin = (http_info.get("final_url") or url) if http_info else url
      report["results"]["operator_fingerprints"] = company_scan(fin, page_html, mods, args.timeout, args.user_agent)
    except Exception as e:
      report["errors"]["company_scan"] = str(e)

  # crt.sh subdomains
  try:
    dom = report["results"]["domain_parsing"].get("registered_domain") or host
    report["results"]["crtsh"] = crtsh_subdomains(dom, mods, args.timeout)
  except Exception as e:
    report["errors"]["crtsh"] = str(e)

  # Playwright evidence
  if args.pw:
    try:
      fin = (http_info.get("final_url") or url) if http_info else url
      art = Path(args.artifacts or f"evidence_{host}")
      report["results"]["playwright"] = pw_capture([fin], art, args.pw_har, args.pw_screens,
                                                      args.pw_pdf, args.pw_axe, args.pw_timeout_ms,
                                                      args.user_agent, mods)
    except Exception as e:
      report["errors"]["playwright"] = str(e)

  report["timestamps"]["finished_utc"] = _utc_iso_now()

  # Optional stderr telemetry (compact)
  if "--telemetry" in (argv or []):
    try:
      t = report
      def _e(msg: str): print(msg, file=sys.stderr)
      tgt = t.get("target", {}).get("normalized_url"); _e(f"[analysis] Target: {tgt}")
      http = t.get("results", {}).get("http", {});
      if http: _e(f"  HTTP {http.get('status_code')} → {http.get('final_url')}")
      tls = t.get("results", {}).get("tls", {});
      if tls: _e(f"  TLS: {tls.get('protocol')} {tls.get('cipher')} exp in {tls.get('days_until_expiry')} days")
      sec = t.get("results", {}).get("vulnerability_audit", {}).get("security_headers", {})
      miss = sec.get("missing") or []
      if miss: _e("  Missing headers: " + ", ".join(miss))
      op = t.get("results", {}).get("operator_fingerprints", {})
      comp = (op.get("extractions", {}) or {}).get("company_names") or []
      if comp: _e("  Company candidates: " + ", ".join(comp[:3]))
      if t.get("results", {}).get("crtsh", {}).get("count"):
        _e(f"  CT subdomains: {t['results']['crtsh']['count']}")
      pw = t.get("results", {}).get("playwright")
      if pw: _e(f"  Playwright: {len((pw or {}).get('pages') or [])} page(s), HAR={'yes' if pw.get('har') else 'no'}")
    except Exception:
      pass

  # Output JSON
  j = json.dumps(report, indent=2, ensure_ascii=False); print(j)
  if args.out:
    try:
      with open(args.out, "w", encoding="utf-8") as f: f.write(j)
    except Exception as e:
      print(f"WARNING: failed to write --out file: {e}", file=sys.stderr)
  return 0


if __name__ == "__main__":
  try:
    sys.exit(main())
  except KeyboardInterrupt:
    print("Interrupted.", file=sys.stderr); sys.exit(130)
  except SystemExit:
    raise
  except Exception as e:
    print(f"Unexpected error: {e}", file=sys.stderr); sys.exit(4)
