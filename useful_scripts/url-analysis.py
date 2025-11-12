#!/usr/bin/env python3
"""
website-analysis — URL intelligence + passive security audit with WordPress focus.

What it does (high level)
  • Recon: DNS, WHOIS/RDAP, HTTP headers, TLS cert (protocol/cipher, expiry), IP geolocation, Wappalyzer (optional).
  • Security headers: checks for HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy,
                      Permissions-Policy, COOP/CORP, etc.; cookie flags (Secure/HttpOnly/SameSite).
  • HTTP behavior: allowed methods via OPTIONS; TRACE detection; mixed-content links on HTTPS pages.
  • Email auth: SPF and DMARC (presence & basic policy sanity + duplicate/misconfiguration checks).
  • WordPress (passive): detect core version (best-effort), enumerate plugin/theme slugs from asset URLs,
                         probe low-risk endpoints (/wp-json, /readme.html, /wp-login.php, /xmlrpc.php, /wp-admin/admin-ajax.php),
                         look for directory indexing (e.g., /wp-content/uploads/).
  • WPScan CVE enrichment (optional, requires API token): known vulns for detected core/plugins/themes.

Ethics
  • Only passive/low-impact HTTP HEAD/GET/OPTIONS requests. No authentication attempts, no fuzzing/brute-force.
  • Respect ToS and local law. Obtain consent for scanning third-party properties.

Exit codes
  0 success, 1 input/usage error, 2 network/timeout, 3 dependency/tool error, 4 unexpected failure.
"""

from __future__ import annotations

import argparse
import datetime as dt
import ipaddress
import json
import re
import socket
import ssl
import subprocess
import sys
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urljoin, urlparse, urlsplit


# ───────────────────────────────────────────────────────────────────────────────
# Optional imports guarded at runtime
# ───────────────────────────────────────────────────────────────────────────────
def _lazy_imports():
    mods = {}
    try:
        import requests  # type: ignore
        mods["requests"] = requests
    except Exception:
        mods["requests"] = None

    try:
        import tldextract  # type: ignore
        mods["tldextract"] = tldextract
    except Exception:
        mods["tldextract"] = None

    try:
        import dns.resolver  # type: ignore
        mods["dnsresolver"] = dns.resolver
    except Exception:
        mods["dnsresolver"] = None

    try:
        import whois as pywhois  # python-whois
        mods["pywhois"] = pywhois
    except Exception:
        mods["pywhois"] = None

    try:
        from bs4 import BeautifulSoup  # type: ignore
        mods["bs4"] = BeautifulSoup
    except Exception:
        mods["bs4"] = None

    return mods


# ───────────────────────────────────────────────────────────────────────────────
# Helpers (time, URL, domain)
# ───────────────────────────────────────────────────────────────────────────────

def _utc_iso_now() -> str:
    """tz-aware ISO8601, second resolution"""
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def normalize_url(raw: str) -> str:
    """Ensure scheme is present; default to https."""
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


def parse_domain(host: str, mods) -> Dict[str, Any]:
    """Return subdomain / domain / suffix with graceful fallback."""
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


# ───────────────────────────────────────────────────────────────────────────────
# DNS / WHOIS / RDAP
# ───────────────────────────────────────────────────────────────────────────────

def dns_query(name: str, rtype: str, mods, timeout: float) -> List[str]:
    dnsresolver = mods.get("dnsresolver")
    if dnsresolver is None:
        return []
    try:
        resolver = dnsresolver.Resolver()
        resolver.lifetime = timeout
        answers = resolver.resolve(name, rtype, lifetime=timeout)
        return [str(r.to_text()) for r in answers]
    except Exception:
        return []


def dns_block(domain: str, mods, timeout: float) -> Dict[str, Any]:
    out = {}
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


def whois_domain(domain: str, mods, timeout: float) -> Dict[str, Any]:
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
    txt = run_system_whois(domain, timeout=timeout)
    if txt:
        result["source"] = "whois(1)"
        result["raw_text"] = txt
        fields = {}
        for key in [
            "Domain Name","Registry Domain ID","Registrar","Registrar IANA ID","Registrar URL",
            "Updated Date","Creation Date","Registry Expiry Date","Registrar Abuse Contact Email",
            "Registrar Abuse Contact Phone","Domain Status","Name Server","DNSSEC","Registrant Organization",
            "Registrant Country","Admin Email","Tech Email",
        ]:
            m = re.findall(rf"^{re.escape(key)}:\s*(.+)$", txt, flags=re.IGNORECASE | re.MULTILINE)
            if m:
                fields[key] = m if len(m) > 1 else m[0]
        result["fields"] = fields
    return result


def rdap_domain(domain: str, mods, timeout: float) -> Optional[Dict[str, Any]]:
    if is_ip(domain):
        return None
    requests = mods.get("requests")
    if requests is None:
        return None
    try:
        r = requests.get(f"https://rdap.org/domain/{domain}", timeout=timeout, headers={"Accept": "application/rdap+json"})
        if r.ok:
            return r.json()
    except Exception:
        return None
    return None


def rdap_ip(ip: str, mods, timeout: float) -> Optional[Dict[str, Any]]:
    requests = mods.get("requests")
    if requests is None:
        return None
    try:
        r = requests.get(f"https://rdap.org/ip/{ip}", timeout=timeout, headers={"Accept": "application/rdap+json"})
        if r.ok:
            return r.json()
    except Exception:
        return None
    return None


# ───────────────────────────────────────────────────────────────────────────────
# HTTP / TLS
# ───────────────────────────────────────────────────────────────────────────────

def http_probe(url: str, mods, timeout: float, user_agent: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {"request_url": url, "final_url": None, "status_code": None, "headers": None}
    requests = mods.get("requests")
    if requests is None:
        return out
    try:
        h = {"User-Agent": user_agent, "Accept": "*/*"}
        resp = requests.head(url, allow_redirects=True, timeout=timeout, headers=h)
        if resp.status_code in (405, 400, 500) or not resp.headers:
            resp = requests.get(url, allow_redirects=True, timeout=timeout, headers=h, stream=True)
        out["final_url"] = str(resp.url)
        out["status_code"] = int(resp.status_code)
        out["headers"] = {k: v for k, v in resp.headers.items()}
        # capture raw Set-Cookie list if available
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


def fetch_html(url: str, mods, timeout: float, user_agent: str, max_bytes: int = 512_000) -> Dict[str, Any]:
    """Fetch a bounded amount of HTML for passive analysis."""
    requests = mods.get("requests")
    out = {"url": url, "status_code": None, "content_type": None, "length": None, "text": None, "error": None}
    if requests is None:
        return out
    try:
        h = {"User-Agent": user_agent, "Accept": "text/html;q=1,*/*;q=0.5"}
        r = requests.get(url, timeout=timeout, headers=h, allow_redirects=True, stream=True)
        out["status_code"] = r.status_code
        ct = r.headers.get("Content-Type", "")
        out["content_type"] = ct
        if "text/html" in ct.lower() and r.status_code < 400:
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
    out: Dict[str, Any] = {"host": host, "port": port, "cert": None, "protocol": None, "cipher": None, "days_until_expiry": None}
    server_hostname = None if is_ip(host) else host
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=server_hostname) as ssock:
                cert = ssock.getpeercert()
                out["protocol"] = ssock.version()
                out["cipher"] = ssock.cipher()
                # OCSP stapling hint (if available)
                try:
                    ocsp = getattr(ssock, "ocsp_response", None)
                    out["ocsp_stapled"] = bool(ocsp) if ocsp is not None else None
                except Exception:
                    out["ocsp_stapled"] = None

                def _name_tuples_to_dict(tups):
                    d = {}
                    for t in tups:
                        if isinstance(t, tuple) and len(t) > 0 and isinstance(t[0], tuple):
                            for k, v in t:
                                d[k] = v
                    return d

                subject = _name_tuples_to_dict(cert.get("subject", ()))
                issuer = _name_tuples_to_dict(cert.get("issuer", ()))
                san = cert.get("subjectAltName", ())
                not_before = cert.get("notBefore")
                not_after = cert.get("notAfter")
                # compute days to expiry
                days_left = None
                if not_after:
                    try:
                        exp = dt.datetime.strptime(not_after, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=dt.timezone.utc)
                        days_left = (exp - dt.datetime.now(dt.timezone.utc)).days
                    except Exception:
                        days_left = None
                out["cert"] = {
                    "subject": subject or None,
                    "issuer": issuer or None,
                    "subjectAltName": [list(x) for x in san] if san else None,
                    "notBefore": not_before,
                    "notAfter": not_after,
                    "version": cert.get("version"),
                    "serialNumber": cert.get("serialNumber"),
                }
                out["days_until_expiry"] = days_left
    except Exception as e:
        out["error"] = str(e)
    return out


# ───────────────────────────────────────────────────────────────────────────────
# Wappalyzer (Node CLI, optional)
# ───────────────────────────────────────────────────────────────────────────────

def run_wappalyzer(url: str, timeout: float) -> Optional[Dict[str, Any]]:
    """
    If the Wappalyzer CLI is installed (e.g., `npm i -g wappalyzer`), run it and parse JSON.
    If not present, return None and we will degrade gracefully.
    """
    from shutil import which
    exe = which("wappalyzer") or which("wappalyzer-cli")
    if not exe:
        return None
    try:
        cp = subprocess.run([exe, url, "-J", "-t", "30"], capture_output=True, text=True, timeout=timeout)
        if cp.returncode == 0 and cp.stdout.strip():
            last_obj = None
            for line in cp.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    last_obj = json.loads(line)
                except Exception:
                    pass
            return last_obj
    except Exception:
        return None
    return None


# ───────────────────────────────────────────────────────────────────────────────
# Security header & cookie analysis
# ───────────────────────────────────────────────────────────────────────────────

def analyze_security_headers(headers: Dict[str, str], set_cookie_list: Optional[List[str]] = None) -> Dict[str, Any]:
    h = {k.lower(): v for k, v in (headers or {}).items()}
    missing: List[str] = []
    info: Dict[str, Any] = {}

    def present(name: str) -> bool:
        return name.lower() in h

    # Core headers
    core = [
        "strict-transport-security",
        "content-security-policy",
        "x-frame-options",
        "x-content-type-options",
        "referrer-policy",
        "permissions-policy",
        "cross-origin-opener-policy",
        "cross-origin-resource-policy",
    ]
    for c in core:
        if not present(c):
            missing.append(c)

    # HSTS sanity
    if present("strict-transport-security"):
        val = h["strict-transport-security"]
        info["hsts"] = val
        low = val.lower()
        if "max-age" not in low:
            missing.append("strict-transport-security:max-age")
        else:
            m = re.search(r"max-age\s*=\s*(\d+)", low)
            if m and int(m.group(1)) < 15552000:  # 180 days
                info["hsts_short_max_age"] = m.group(1)
        if "includesubdomains" not in low:
            info["hsts_note"] = "Consider includeSubDomains; preload requires it."
        if "preload" not in low:
            info["hsts_preload_hint"] = "Eligible for preload only with 'preload' and long max-age."

    # X-Content-Type-Options exactness
    if present("x-content-type-options") and h["x-content-type-options"].lower() != "nosniff":
        info["x_content_type_options_note"] = "Use 'nosniff'."

    # CSP lint
    csp = h.get("content-security-policy")
    if csp:
        bad = []
        low = csp.lower()
        if "unsafe-inline" in low or "unsafe-eval" in low:
            bad.append("uses 'unsafe-inline'/'unsafe-eval'")
        if re.search(r"(^|\s)default-src\s+[^;]*\*", low):
            bad.append("default-src allows '*'")
        if "http:" in low:
            bad.append("allows http: in CSP on HTTPS site")
        if "object-src" not in low:
            bad.append("missing object-src 'none'")
        if "frame-ancestors" not in low:
            bad.append("missing frame-ancestors")
        if bad:
            info["csp_findings"] = bad

    # Referrer-Policy
    rp = h.get("referrer-policy")
    if not rp:
        info["referrer_policy_note"] = "Missing Referrer-Policy (consider 'strict-origin-when-cross-origin' or stricter)."
    elif rp.strip().lower() in {"no-referrer-when-downgrade", "unsafe-url"}:
        info["referrer_policy_note"] = f"Referrer-Policy is '{rp}' (weaker than recommended)."

    # Permissions-Policy sanity (very light)
    if not h.get("permissions-policy"):
        info["permissions_policy_note"] = "Missing Permissions-Policy."

    # Cookies
    cookies: List[Dict[str, Any]] = []
    raw_cookie_headers = set_cookie_list or ([] if "set-cookie" not in h else [h["set-cookie"]])
    for raw in raw_cookie_headers:
        for c in raw.split("\n"):  # some proxies fold headers
            c = c.strip()
            if not c:
                continue
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


# ───────────────────────────────────────────────────────────────────────────────
# SPF / DMARC (email posture)
# ───────────────────────────────────────────────────────────────────────────────

def _parse_dmarc(txt: str) -> Dict[str, str]:
    parts: Dict[str, str] = {}
    for kv in txt.split(";"):
        kv = kv.strip()
        if not kv or "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        parts[k.strip().lower()] = v.strip()
    return parts


def analyze_email_posture(domain: str, dns_records: Dict[str, Any], mods, timeout: float) -> Dict[str, Any]:
    out: Dict[str, Any] = {"spf": None, "dmarc": None, "issues": []}
    # SPF
    spf_txt: List[str] = []
    for t in (dns_records or {}).get("TXT", []):
        if "v=spf1" in t.lower():
            spf_txt.append(t.strip('"'))
    out["spf"] = spf_txt or None

    # Duplicate SPF
    if len(spf_txt) > 1:
        out["issues"].append("Multiple SPF v=spf1 TXT records present (must be exactly one).")

    # SPF lookup budget (RFC 7208 limit: 10 includes/qualifiers that trigger DNS lookups)
    spf_joined = " ".join(spf_txt)
    lookups = 0
    for token in re.findall(r"(?::|^|\s)(include:[^\s]+|a\b|mx\b|exists:[^\s]+|ptr\b|redirect=\S+)", spf_joined, flags=re.I):
        kind = token.split(":")[0].split("=")[0].lower()
        if kind in {"include", "a", "mx", "exists", "ptr", "redirect"}:
            lookups += 1
    if lookups > 10:
        out["issues"].append(f"SPF may exceed the 10-DNS-lookup limit (estimated {lookups}). Consider flattening or pruning 'a/mx'.")
    if not spf_txt:
        out["issues"].append("SPF record missing.")
    else:
        if any(("+all" in s.lower()) for s in spf_txt):
            out["issues"].append("SPF uses +all (permits everyone) — unsafe.")
        if " ptr" in (" " + spf_joined.lower() + " "):
            out["issues"].append("SPF uses 'ptr' (deprecated).")
        if not any(("~all" in s.lower()) or ("-all" in s.lower()) for s in spf_txt):
            out["issues"].append("SPF lacks an explicit ~all or -all mechanism.")

    # DMARC
    dmarc = dns_query(f"_dmarc.{domain}", "TXT", mods, timeout)
    if len(dmarc) > 1:
        out["issues"].append("Multiple DMARC TXT records present (must be exactly one).")
    if dmarc:
        txt = "; ".join([x.strip('"') for x in dmarc])
        out["dmarc"] = txt
        details = _parse_dmarc(txt)
        out["dmarc_details"] = details
        pol = details.get("p", "").lower()
        if not pol:
            out["issues"].append("DMARC found but no policy 'p='.")
        elif pol == "none":
            out["issues"].append("DMARC p=none (monitor only). Consider 'quarantine' or 'reject'.")
        if details.get("adkim", "r").lower() != "s" or details.get("aspf", "r").lower() != "s":
            out["issues"].append("DMARC alignment relaxed (adkim/aspf != s).")
        if "rua" not in details:
            out["issues"].append("DMARC missing aggregate reporting (rua).")
    else:
        out["issues"].append("DMARC record missing (_dmarc).")
    return out


# ───────────────────────────────────────────────────────────────────────────────
# WordPress passive detection & checks
# ───────────────────────────────────────────────────────────────────────────────

_version_re = re.compile(r"^\d+(?:\.\d+){1,3}$")

def _parse_assets_for_wp_slugs(page_url: str, html: str) -> Dict[str, Any]:
    """Extract plugin/theme slugs and versions from asset URLs and meta generator."""
    slugs = {"plugins": {}, "themes": {}, "core_version": None, "generator": None}
    # meta generator
    gen = re.search(r'<meta[^>]+name=["\']generator["\'][^>]+content=["\']([^"\']+)["\']', html, re.I)
    if gen:
        slugs["generator"] = gen.group(1)
        m = re.search(r"WordPress\s+([\d\.]+)", slugs["generator"], re.I)
        if m:
            slugs["core_version"] = m.group(1)

    # asset-based hints (?ver=6.x.y)
    for m in re.finditer(r"""(?:href|src)\s*=\s*["']([^"']+)["']""", html, re.I):
        url = m.group(1)
        if "/wp-content/plugins/" in url:
            try:
                p = urlsplit(url)
                parts = p.path.split("/")
                idx = parts.index("plugins")
                slug = parts[idx + 1] if len(parts) > idx + 1 else None
                if slug:
                    ver = parse_qs(p.query).get("ver", [None])[0]
                    if slug not in slugs["plugins"]:
                        slugs["plugins"][slug] = {"versions_seen": set()}
                    if ver and _version_re.match(ver):
                        slugs["plugins"][slug]["versions_seen"].add(ver)
            except Exception:
                pass
        if "/wp-content/themes/" in url:
            try:
                p = urlsplit(url)
                parts = p.path.split("/")
                idx = parts.index("themes")
                slug = parts[idx + 1] if len(parts) > idx + 1 else None
                if slug:
                    ver = parse_qs(p.query).get("ver", [None])[0]
                    if slug not in slugs["themes"]:
                        slugs["themes"][slug] = {"versions_seen": set()}
                    if ver and _version_re.match(ver):
                        slugs["themes"][slug]["versions_seen"].add(ver)
            except Exception:
                pass
        # core version often leaks via wp-emoji or wp-includes assets
        if "/wp-includes/" in url and "ver=" in url:
            v = parse_qs(urlsplit(url).query).get("ver", [None])[0]
            if v and not slugs["core_version"] and _version_re.match(v):
                slugs["core_version"] = v

    # convert sets to lists for JSON
    for d in (slugs["plugins"], slugs["themes"]):
        for k, v in d.items():
            v["versions_seen"] = sorted(list(v["versions_seen"]))
    return slugs


def probe_endpoint(url: str, mods, timeout: float, user_agent: str, method: str = "HEAD") -> Dict[str, Any]:
    requests = mods.get("requests")
    out = {"url": url, "status": None, "length": None, "note": None, "error": None}
    if requests is None:
        return out
    try:
        h = {"User-Agent": user_agent, "Accept": "*/*"}
        if method == "HEAD":
            r = requests.head(url, timeout=timeout, headers=h, allow_redirects=True)
        elif method == "GET":
            r = requests.get(url, timeout=timeout, headers=h, allow_redirects=True)
        elif method == "OPTIONS":
            r = requests.options(url, timeout=timeout, headers=h, allow_redirects=True)
        else:
            r = requests.request(method, url, timeout=timeout, headers=h, allow_redirects=True)
        out["status"] = r.status_code
        out["length"] = int(r.headers.get("Content-Length", "0")) if r.headers.get("Content-Length") else None
        # Minimal body sniff for index listings
        if method == "GET" and r.ok and "text/html" in r.headers.get("Content-Type", "").lower():
            text = r.text[:8192]
            if "Index of /" in text:
                out["note"] = "directory_indexing"
    except Exception as e:
        out["error"] = str(e)
    return out


def detect_wordpress(url: str, base_html: Optional[str], mods, timeout: float, user_agent: str) -> Dict[str, Any]:
    """Passive WP detection and low-risk endpoint checks."""
    out: Dict[str, Any] = {
        "detected": False,
        "core_version_hint": None,
        "generator": None,
        "plugins": {},
        "themes": {},
        "endpoints": {},
        "issues": [],
    }

    if base_html:
        p = _parse_assets_for_wp_slugs(url, base_html)
        out["generator"] = p["generator"]
        out["core_version_hint"] = p["core_version"]
        out["plugins"] = p["plugins"]
        out["themes"] = p["themes"]
        if p["core_version"] or "/wp-content/" in base_html or "/wp-includes/" in base_html or (p["generator"] and "wordpress" in p["generator"].lower()):
            out["detected"] = True

    # REST API root
    rest = probe_endpoint(urljoin(url, "/wp-json/"), mods, timeout, user_agent, method="GET")
    out["endpoints"]["/wp-json/"] = rest
    if rest.get("status") in (200, 401, 403):
        out["detected"] = True
        # Optionally keep a tiny sample (not the full routes to keep output small)
        try:
            requests = mods.get("requests")
            if requests and rest.get("status") == 200:
                r = requests.get(urljoin(url, "/wp-json/"), timeout=timeout, headers={"User-Agent": user_agent})
                if r.ok:
                    j = r.json()
                    out["rest_root_sample"] = {k: j.get(k) for k in ["name", "description", "url", "home"] if k in j}
        except Exception:
            pass

    # readme.html (should be removed/blocked)
    readme = probe_endpoint(urljoin(url, "/readme.html"), mods, timeout, user_agent, method="GET")
    out["endpoints"]["/readme.html"] = readme
    if readme.get("status") == 200:
        out["issues"].append("WordPress readme.html is accessible (discloses version).")

    # login page
    login = probe_endpoint(urljoin(url, "/wp-login.php"), mods, timeout, user_agent, method="HEAD")
    out["endpoints"]["/wp-login.php"] = login

    # admin-ajax (existence is normal but confirms WP)
    admin_ajax = probe_endpoint(urljoin(url, "/wp-admin/admin-ajax.php"), mods, timeout, user_agent, method="HEAD")
    out["endpoints"]["/wp-admin/admin-ajax.php"] = admin_ajax
    if admin_ajax.get("status") in (200, 400, 405):
        out["detected"] = True

    # xmlrpc
    xmlrpc = probe_endpoint(urljoin(url, "/xmlrpc.php"), mods, timeout, user_agent, method="GET")
    out["endpoints"]["/xmlrpc.php"] = xmlrpc
    if xmlrpc.get("status") in (200, 405):  # 405: method must be POST -> exposed
        out["issues"].append("xmlrpc.php is enabled (consider disabling or restricting).")

    # uploads dir listing
    uploads = probe_endpoint(urljoin(url, "/wp-content/uploads/"), mods, timeout, user_agent, method="GET")
    out["endpoints"]["/wp-content/uploads/"] = uploads
    if uploads.get("note") == "directory_indexing":
        out["issues"].append("Directory indexing enabled under /wp-content/uploads/.")

    return out


# ───────────────────────────────────────────────────────────────────────────────
# Mixed content, HTTP methods, sensitive files
# ───────────────────────────────────────────────────────────────────────────────

def find_mixed_content(base_url: str, html: Optional[str]) -> List[str]:
    if not html or not base_url.lower().startswith("https://"):
        return []
    bad: List[str] = []
    for m in re.finditer(r"""(?:src|href)\s*=\s*["'](http://[^"']+)["']""", html, re.I):
        bad.append(m.group(1))
    return sorted(list(set(bad)))[:50]


def allowed_methods(url: str, mods, timeout: float, user_agent: str) -> Dict[str, Any]:
    r = probe_endpoint(url, mods, timeout, user_agent, method="OPTIONS")
    allow = None
    if r.get("status") and r.get("status") < 500:
        try:
            requests = mods.get("requests")
            if requests:
                resp = requests.options(url, timeout=timeout, headers={"User-Agent": user_agent})
                allow = resp.headers.get("Allow")
        except Exception:
            pass
    out = {"status": r.get("status"), "allow": allow}
    # TRACE probing (dangerous echo)
    try:
        requests = mods.get("requests")
        if requests:
            tr = requests.request("TRACE", url, timeout=timeout, headers={"User-Agent": user_agent})
            out["trace_status"] = tr.status_code
    except Exception:
        out["trace_status"] = None
    return out


def check_sensitive_files(url: str, mods, timeout: float, user_agent: str) -> List[Dict[str, Any]]:
    candidates = [
        "/wp-config.php", "/wp-config.php.bak", "/wp-config.php~", "/wp-config.zip", "/wp-config.tar.gz",
        "/backup.zip", "/backup.tar.gz", "/database.sql", "/.env", "/.git/config", "/.git/HEAD", "/.gitignore",
        "/.svn/entries", "/.DS_Store", "/.user.ini", "/phpinfo.php", "/wp-config-sample.php", "/wp-content/debug.log",
        "/.well-known/security.txt",
    ]
    findings: List[Dict[str, Any]] = []
    for path in candidates:
        r = probe_endpoint(urljoin(url, path), mods, timeout, user_agent, method="HEAD")
        st = r.get("status")
        if st and st < 400:
            findings.append({"path": path, "status": st, "note": "unexpectedly accessible"})
        elif st == 403:
            findings.append({"path": path, "status": st, "note": "forbidden (OK)"})
    return findings


# ───────────────────────────────────────────────────────────────────────────────
# WPScan API enrichment (optional)
# ───────────────────────────────────────────────────────────────────────────────

def wpscan_lookup(kind: str, key: str, token: str, mods, timeout: float) -> Optional[Dict[str, Any]]:
    """
    kind: 'wordpresses' | 'plugins' | 'themes'
    key: version string (for wordpresses) or slug (for plugins/themes)
    """
    requests = mods.get("requests")
    if not requests or not token:
        return None
    base = f"https://wpscan.com/api/v3/{kind}/{key}"
    try:
        r = requests.get(base, timeout=timeout, headers={"Authorization": f"Token token={token}", "Accept": "application/json"})
        if r.status_code == 404:
            return {"note": "No entry found."}
        if r.ok:
            return r.json()
        return {"error": f"HTTP {r.status_code}", "body": r.text[:2000]}
    except Exception as e:
        return {"error": str(e)}


def enrich_with_wpscan(token: str, wp_info: Dict[str, Any], mods, timeout: float) -> Dict[str, Any]:
    out: Dict[str, Any] = {"core": None, "plugins": {}, "themes": {}, "errors": []}
    if not token:
        return out
    ver = (wp_info.get("core_version_hint") or "").strip()
    if ver:
        out["core"] = wpscan_lookup("wordpresses", ver, token, mods, timeout)
    for slug in (wp_info.get("plugins") or {}).keys():
        out["plugins"][slug] = wpscan_lookup("plugins", slug, token, mods, timeout)
    for slug in (wp_info.get("themes") or {}).keys():
        out["themes"][slug] = wpscan_lookup("themes", slug, token, mods, timeout)
    return out


# ───────────────────────────────────────────────────────────────────────────────
# Optional: visible telemetry (stdout-safe summary to stderr)
# ───────────────────────────────────────────────────────────────────────────────

def _print_telemetry(report: Dict[str, Any]) -> None:
    """Print a concise human summary to stderr (opt-in with --telemetry)."""
    try:
        t = report
        def _e(msg: str): print(msg, file=sys.stderr)
        tgt = t.get("target", {}).get("normalized_url")
        _e(f"[website-analysis] Target: {tgt}")
        http = t.get("results", {}).get("http", {})
        if http:
            _e(f"  HTTP {http.get('status_code')} → {http.get('final_url')}")
        tls = t.get("results", {}).get("tls", {})
        if tls:
            _e(f"  TLS: {tls.get('protocol')} {tls.get('cipher')} exp in {tls.get('days_until_expiry')} days")
        sec = t.get("results", {}).get("vulnerability_audit", {}).get("security_headers", {})
        miss = sec.get("missing") or []
        if miss:
            _e(f"  Missing headers: {', '.join(miss)}")
        wp = t.get("results", {}).get("vulnerability_audit", {}).get("wordpress", {})
        if wp and wp.get("detected"):
            _e(f"  WordPress detected; core≈{wp.get('core_version_hint')} plugins={len(wp.get('plugins') or {})} themes={len(wp.get('themes') or {})}")
    except Exception:
        pass


# ───────────────────────────────────────────────────────────────────────────────
# Main
# ───────────────────────────────────────────────────────────────────────────────

def build_arg_parser() -> argparse.ArgumentParser:
    epilog = r"""
EXAMPLES
  Basic:
    website-analysis https://example.com

  Save JSON:
    website-analysis example.com --out report.json

  Privacy-lean (no Geo, no Wappalyzer):
    website-analysis example.com --no-geo --no-wappalyzer

  Faster timeout + custom UA:
    website-analysis example.com -T 5 -A "Mozilla/5.0 (ResearchBot)"

  WPScan CVE enrichment:
    website-analysis examplewp.tld --wpscan-api-token "$WPSCAN_TOKEN"
"""
    p = argparse.ArgumentParser(
        prog="website-analysis",
        description="Audit a URL: DNS/WHOIS/RDAP, HTTP/TLS, security headers, email SPF/DMARC, WordPress passive checks, optional CVE enrichment.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=epilog,
    )
    p.add_argument("url", help="Target URL or hostname (scheme optional; https assumed).")
    p.add_argument("--out", metavar="FILE", help="Write full JSON report to FILE.")
    p.add_argument("-T", "--timeout", type=float, default=15.0, help="Network timeout in seconds (default: 15).")
    p.add_argument("-A", "--user-agent", default="website-analysis/2.0 (+local use)", help="HTTP User-Agent.")

    # Feature toggles
    p.add_argument("--no-dns", action="store_true", help="Disable DNS record lookup.")
    p.add_argument("--no-whois", action="store_true", help="Disable WHOIS lookup.")
    p.add_argument("--no-rdap", action="store_true", help="Disable RDAP lookups (domain & IP).")
    p.add_argument("--no-http", action="store_true", help="Disable HTTP probe.")
    p.add_argument("--no-tls", action="store_true", help="Disable TLS certificate probe.")
    p.add_argument("--no-geo", action="store_true", help="Disable IP geolocation.")
    p.add_argument("--no-wappalyzer", dest="no_wappalyzer", action="store_true", help="Disable Wappalyzer tech fingerprint.")

    # Vulnerability audit layer
    p.add_argument("--no-vuln", action="store_true", help="Disable passive vulnerability checks (security headers, WP, etc.).")
    p.add_argument("--plugin-readmes", action="store_true", help="Lightly probe plugin readme.txt for version hints.")
    p.add_argument("--wpscan-api-token", default="", help="WPScan API token for CVE enrichment (optional).")

    # Optional human-readable summary
    p.add_argument("--telemetry", action="store_true", help="Print a one-line summary per section to stderr.")
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    mods = _lazy_imports()

    # Normalize URL and parse host
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
        },
        "results": {},
        "errors": {},
    }

    # Domain parsing (informational)
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

    # WHOIS (domain)
    if not args.no_whois and not is_ip(host):
        try:
            dom = report["results"]["domain_parsing"].get("registered_domain") or host
            report["results"]["whois"] = whois_domain(dom, mods, args.timeout)
        except Exception as e:
            report["errors"]["whois"] = str(e)

    # RDAP (domain)
    if not args.no_rdap and not is_ip(host):
        try:
            dom = report["results"]["domain_parsing"].get("registered_domain") or host
            report["results"]["rdap_domain"] = rdap_domain(dom, mods, args.timeout)
        except Exception as e:
            report["errors"]["rdap_domain"] = str(e)

    # IP selection
    ips: List[str] = []
    try:
        if dns_records.get("A"):
            ips.extend([x.split()[0] if " " in x else x for x in dns_records["A"]])
        if dns_records.get("AAAA"):
            ips.extend([x.split()[0] if " " in x else x for x in dns_records["AAAA"]])
        if not ips:
            infos = socket.getaddrinfo(host, None)
            for fam, _, _, _, sockaddr in infos:
                if fam == socket.AF_INET:
                    ips.append(sockaddr[0])
                elif fam == socket.AF_INET6:
                    ips.append(sockaddr[0])
        report["results"]["resolved_ips"] = sorted(list(set(ips)))
    except Exception as e:
        report["errors"]["resolve"] = str(e)

    # RDAP/IP + geolocation (first IP)
    ip0 = ips[0] if ips else None
    if ip0:
        if not args.no_rdap:
            try:
                report["results"]["rdap_ip"] = rdap_ip(ip0, mods, args.timeout)
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
                    if r.ok:
                        report["results"]["ip_geolocation"] = r.json()
            except Exception as e:
                report["errors"]["ip_geolocation"] = str(e)

    # HTTP probe
    http_info: Dict[str, Any] = {}
    if not args.no_http:
        try:
            http_info = http_probe(url, mods, args.timeout, args.user_agent)
            report["results"]["http"] = http_info
        except Exception as e:
            report["errors"]["http"] = str(e)

    # TLS probe
    if not args.no_tls:
        try:
            report["results"]["tls"] = tls_probe(host, 443, args.timeout)
        except Exception as e:
            report["errors"]["tls"] = str(e)

    # Wappalyzer (Node)
    if not args.no_wappalyzer:
        try:
            w = run_wappalyzer(url, timeout=max(10.0, args.timeout))
            report["results"]["wappalyzer"] = w
            if w is None:
                report["errors"]["wappalyzer"] = "Wappalyzer CLI not found or failed; install with: npm i -g wappalyzer"
        except Exception as e:
            report["errors"]["wappalyzer"] = str(e)

    # Vulnerability & posture analysis (passive)
    if not args.no_vuln:
        vuln: Dict[str, Any] = {
            "security_headers": None,
            "http_methods": None,
            "mixed_content": None,
            "sensitive_files": None,
            "email_posture": None,
            "wordpress": None,
            "wpscan": None,
            "notes": [],
        }
        # Security headers + cookies
        try:
            headers = (http_info or {}).get("headers") or {}
            set_cookie_list = (http_info or {}).get("set_cookie_list")
            vuln["security_headers"] = analyze_security_headers(headers, set_cookie_list)
        except Exception as e:
            report["errors"]["security_headers"] = str(e)

        # Allowed methods & TRACE
        try:
            fin = (http_info.get("final_url") or url) if http_info else url
            vuln["http_methods"] = allowed_methods(fin, mods, args.timeout, args.user_agent)
        except Exception as e:
            report["errors"]["http_methods"] = str(e)

        # Fetch HTML for passive content analysis
        page_html: Optional[str] = None
        try:
            fin_url = (http_info or {}).get("final_url") or url
            fetched = fetch_html(fin_url, mods, args.timeout, args.user_agent, max_bytes=512_000)
            if fetched.get("text"):
                page_html = fetched["text"]
            report["results"]["page_snippet"] = {
                "url": fetched.get("url"),
                "status_code": fetched.get("status_code"),
                "content_type": fetched.get("content_type"),
                "length": fetched.get("length"),
            }
        except Exception as e:
            report["errors"]["fetch_html"] = str(e)

        # Mixed content (on HTTPS pages)
        try:
            vuln["mixed_content"] = find_mixed_content((http_info.get("final_url") or url) if http_info else url, page_html)
        except Exception as e:
            report["errors"]["mixed_content"] = str(e)

        # Sensitive files quick check
        try:
            vuln["sensitive_files"] = check_sensitive_files((http_info.get("final_url") or url) if http_info else url, mods, args.timeout, args.user_agent)
        except Exception as e:
            report["errors"]["sensitive_files"] = str(e)

        # SPF/DMARC
        try:
            dom = report["results"]["domain_parsing"].get("registered_domain") or host
            vuln["email_posture"] = analyze_email_posture(dom, dns_records, mods, args.timeout)
        except Exception as e:
            report["errors"]["email_posture"] = str(e)

        # WordPress passive detection
        wp_info = None
        try:
            fin_url = (http_info.get("final_url") or url) if http_info else url
            wp_info = detect_wordpress(fin_url, page_html, mods, args.timeout, args.user_agent)
            vuln["wordpress"] = wp_info
        except Exception as e:
            report["errors"]["wordpress"] = str(e)

        # Optional: peek plugin readmes for stable tag
        try:
            if args.plugin_readmes and wp_info and wp_info.get("plugins"):
                # minimal inline peek to avoid another helper; keep output compact
                details: Dict[str, Any] = {}
                requests = mods.get("requests")
                if requests:
                    for slug in list(wp_info["plugins"].keys())[:25]:
                        u = urljoin((http_info.get("final_url") or url) if http_info else url, f"/wp-content/plugins/{slug}/readme.txt")
                        try:
                            r = requests.get(u, timeout=args.timeout, headers={"User-Agent": args.user_agent, "Range": "bytes=0-2048"})
                            if r.status_code in (200, 206) and "text" in r.headers.get("Content-Type","").lower():
                                m = re.search(r"(?im)^\s*Stable\s+tag:\s*([0-9][0-9.\-a-zA-Z]+)\s*$", r.text)
                                details[slug] = {"status": r.status_code, "stable_tag": m.group(1) if m else None}
                        except Exception as e:
                            details[slug] = {"error": str(e)}
                vuln.setdefault("wordpress_details", {})["plugin_readmes"] = details
        except Exception as e:
            report["errors"]["plugin_readmes"] = str(e)

        # WPScan enrichment
        try:
            token = args.wpscan_api_token.strip()
            if token and wp_info and (wp_info.get("detected") or wp_info.get("plugins") or wp_info.get("themes")):
                vuln["wpscan"] = enrich_with_wpscan(token, wp_info, mods, args.timeout)
            elif token:
                vuln["notes"].append("WPScan token provided but WordPress not confidently detected.")
        except Exception as e:
            report["errors"]["wpscan"] = str(e)

        report["results"]["vulnerability_audit"] = vuln

    report["timestamps"]["finished_utc"] = _utc_iso_now()

    # Optional stderr telemetry
    if args.telemetry:
        _print_telemetry(report)

    # Output
    j = json.dumps(report, indent=2, ensure_ascii=False)
    print(j)
    if args.out:
        try:
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(j)
        except Exception as e:
            print(f"WARNING: failed to write --out file: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        sys.exit(130)
    except SystemExit:
        raise
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        sys.exit(4)

