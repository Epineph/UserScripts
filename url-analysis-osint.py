#!/usr/bin/env python3
# ──────────────────────────────────────────────────────────────────────────────
# osint_evidence_pack.py — Passive OSINT + evidence bundle for scam reporting
# Line width target: 81 cols; 2-space indents.
# ──────────────────────────────────────────────────────────────────────────────
"""
LEGAL SCOPE
  • Passive collection only: public HTTP(S), DNS, WHOIS/RDAP, CT logs, Wayback.
  • Optional user-driven browsing via Playwright to export HAR/screens/cookies.
  • No auth guessing, fuzzing, uptime impact, or vulnerability exploitation.

OUTPUT
  evidence/<domain>-<UTCstamp>/
    - summary.json                 # All structured findings
    - headers.json                 # Raw header snapshot
    - tls.json                     # Certificate & cipher details
    - whois.txt / rdap_domain.json / rdap_ip.json
    - dns_current.json             # A/AAAA/NS/MX/TXT/SOA, etc.
    - ct_subdomains.csv            # From crt.sh
    - wayback.csv                  # Snapshot index
    - crawl.csv                    # Pages visited + hashes
    - artifacts/                   # HTML saves, screenshots, HAR, cookies.json
    - report.md                    # Pre-filled abuse report (Cloudflare/Gname)

INSTALL
  pip install requests dnspython tldextract beautifulsoup4 pandas rich
  pip install playwright
  python -m playwright install --with-deps chromium
"""

from __future__ import annotations
import argparse, datetime as dt, hashlib, ipaddress, json, os, re, ssl, csv
import socket, sys, time
from pathlib import Path
from urllib.parse import urlparse, urljoin, urlsplit
from typing import Dict, List, Optional, Tuple

# Third-party
import requests
import dns.resolver
import tldextract
from bs4 import BeautifulSoup
import pandas as pd

# Playwright is optional; imported lazily
PW = None

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

def utc_now() -> str:
  return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

def ensure_dir(p: Path) -> None:
  p.mkdir(parents=True, exist_ok=True)

def norm_url(u: str) -> str:
  u = u.strip()
  if not re.match(r"^[a-zA-Z][a-zA-Z0-9+\-.]*://", u):
    u = "https://" + u
  return u

def host_from(u: str) -> str:
  h = urlparse(u).hostname
  if not h: raise SystemExit("Unable to extract hostname.")
  return h

def is_ip(s: str) -> bool:
  try:
    ipaddress.ip_address(s); return True
  except ValueError:
    return False

def sha256_bytes(b: bytes) -> str:
  return hashlib.sha256(b).hexdigest()

# ──────────────────────────────────────────────────────────────────────────────
# DNS / WHOIS / RDAP / TLS
# ──────────────────────────────────────────────────────────────────────────────

def dns_all(domain: str, timeout: float = 10.0) -> Dict[str, List[str]]:
  out: Dict[str, List[str]] = {}
  r = dns.resolver.Resolver()
  r.lifetime = timeout
  for rr in ["A","AAAA","NS","MX","TXT","SOA","CAA"]:
    try:
      answers = r.resolve(domain, rr, lifetime=timeout, raise_on_no_answer=False)
      if getattr(answers, "rrset", None) is None:
        continue
      out[rr] = [str(rdata.to_text()) for rdata in answers]
    except (dns.resolver.NXDOMAIN,
            dns.resolver.NoAnswer,
            dns.resolver.NoNameservers,
            dns.exception.Timeout):
      pass
  return out


def whois_text(domain: str, timeout: float = 20.0) -> Optional[str]:
  from shutil import which
  exe = which("whois")
  if not exe: return None
  try:
    cp = requests.utils.requote_uri(domain)  # harmless normalization
    p = os.popen(f"timeout {int(timeout)} whois {cp}")
    data = p.read()
    return data if data.strip() else None
  except Exception:
    return None

def rdap_get(url: str, timeout: float = 15.0) -> Optional[dict]:
  try:
    r = requests.get(url, timeout=timeout, headers={"Accept":"application/rdap+json"})
    return r.json() if r.ok else None
  except Exception:
    return None

def rdap_domain(domain: str, timeout: float = 15.0) -> Optional[dict]:
  if is_ip(domain): return None
  return rdap_get(f"https://rdap.org/domain/{domain}", timeout)

def rdap_ip(ip: str, timeout: float = 15.0) -> Optional[dict]:
  return rdap_get(f"https://rdap.org/ip/{ip}", timeout)

def tls_probe(host: str, port: int = 443, timeout: float = 10.0) -> dict:
  out = {"host": host, "port": port}
  try:
    ctx = ssl.create_default_context()
    with socket.create_connection((host, port), timeout=timeout) as sock:
      with ctx.wrap_socket(sock, server_hostname=None if is_ip(host) else host) as s:
        cert = s.getpeercert()
        out["protocol"] = s.version()
        out["cipher"] = s.cipher()
        out["cert"] = {
          "subject": cert.get("subject"),
          "issuer": cert.get("issuer"),
          "subjectAltName": cert.get("subjectAltName"),
          "notBefore": cert.get("notBefore"),
          "notAfter": cert.get("notAfter"),
          "serialNumber": cert.get("serialNumber"),
          "version": cert.get("version"),
        }
  except Exception as e:
    out["error"] = str(e)
  return out

# ──────────────────────────────────────────────────────────────────────────────
# HTTP snapshot
# ──────────────────────────────────────────────────────────────────────────────

def grab_headers(url: str, timeout: float = 15.0, ua: str = "OSINT/1.0"):
  try:
    h = {"User-Agent": ua, "Accept": "*/*"}
    r = requests.head(url, allow_redirects=True, timeout=timeout, headers=h)
    if r.status_code in (405, 400) or not r.headers:
      r = requests.get(url, allow_redirects=True, timeout=timeout, headers=h, stream=True)
    return {
      "final_url": str(r.url),
      "status": int(r.status_code),
      "headers": dict(r.headers.items()),
      "set_cookie": list(r.raw.headers.get_all("Set-Cookie") or []) \
                    if hasattr(r.raw, "headers") else [],
    }
  except Exception as e:
    return {"error": str(e)}

def fetch_html(url: str, timeout: float = 20.0, ua: str = "OSINT/1.0",
               cap_bytes: int = 600_000) -> Tuple[Optional[str], Optional[str]]:
  try:
    r = requests.get(url, timeout=timeout, headers={"User-Agent": ua}, stream=True)
    ct = r.headers.get("Content-Type","")
    if "text/html" not in ct.lower() or r.status_code >= 400:
      return None, ct
    buf = bytearray()
    for chunk in r.iter_content(8192):
      if chunk:
        if len(buf)+len(chunk) > cap_bytes:
          buf.extend(chunk[:cap_bytes-len(buf)]); break
        buf.extend(chunk)
    enc = r.encoding or "utf-8"
    return buf.decode(enc, errors="replace"), ct
  except Exception:
    return None, None

# ──────────────────────────────────────────────────────────────────────────────
# CT (crt.sh), Wayback
# ──────────────────────────────────────────────────────────────────────────────

def ct_subdomains(domain: str, timeout: float = 25.0) -> pd.DataFrame:
  # crt.sh supports JSON output; rates are modest so keep polite.
  url = f"https://crt.sh/?q=%.{domain}&output=json"
  try:
    r = requests.get(url, timeout=timeout)
    if not r.ok: return pd.DataFrame()
    data = r.json()
    rows = []
    for it in data:
      name = it.get("name_value","").lower()
      for n in set(name.splitlines()):
        rows.append({
          "name": n.strip(),
          "issuer_ca_id": it.get("issuer_ca_id"),
          "issuer_name": it.get("issuer_name"),
          "not_before": it.get("not_before"),
          "not_after": it.get("not_after"),
          "entry_timestamp": it.get("entry_timestamp"),
        })
    df = pd.DataFrame(rows).drop_duplicates().sort_values("name")
    return df
  except Exception:
    return pd.DataFrame()

def wayback_cdx(domain: str, timeout: float = 25.0) -> pd.DataFrame:
  # Query snapshots for root and wildcard paths (cap to 2000 entries).
  base = "http://web.archive.org/cdx/search/cdx"
  params = {
    "url": f"{domain}/*",
    "output": "json",
    "fl": "timestamp,original,statuscode,mimetype,length,digest",
    "filter": "statuscode:200",
    "limit": "2000",
  }
  try:
    r = requests.get(base, params=params, timeout=timeout)
    if not r.ok or not r.text.strip(): return pd.DataFrame()
    js = r.json()
    if not js or len(js) < 2: return pd.DataFrame()
    cols, data = js[0], js[1:]
    df = pd.DataFrame(data, columns=cols)
    return df
  except Exception:
    return pd.DataFrame()

def wayback_save_now(url: str, timeout: float = 30.0) -> Optional[str]:
  try:
    r = requests.get("https://web.archive.org/save/" + url, timeout=timeout)
    if r.ok:
      return r.headers.get("Content-Location")
  except Exception:
    pass
  return None

# ──────────────────────────────────────────────────────────────────────────────
# Light crawler (same-origin)
# ──────────────────────────────────────────────────────────────────────────────

def same_origin(u0: str, u1: str) -> bool:
  p0, p1 = urlparse(u0), urlparse(u1)
  return (p0.scheme, p0.hostname) == (p1.scheme, p1.hostname)

def crawl(start_url: str, limit: int = 50, timeout: float = 15.0) -> List[dict]:
  seen, q, out = set(), [start_url], []
  while q and len(out) < limit:
    u = q.pop(0)
    if u in seen: continue
    seen.add(u)
    try:
      r = requests.get(u, timeout=timeout, headers={"User-Agent":"OSINT/1.0"})
      body = r.text if ("text/html" in r.headers.get("Content-Type","").lower()) else ""
      out.append({
        "url": u, "status": r.status_code,
        "sha256": sha256_bytes(r.content),
        "title": BeautifulSoup(body, "html.parser").title.string.strip() \
                 if body and BeautifulSoup(body,"html.parser").title else None
      })
      if body and r.ok:
        for a in BeautifulSoup(body, "html.parser").find_all("a", href=True):
          tgt = urljoin(u, a["href"])
          if same_origin(start_url, tgt):
            # Keep only likely HTML pages.
            if not re.search(r"\.(png|jpg|gif|css|js|pdf|zip|mp4)(\?|$)", tgt, re.I):
              q.append(tgt)
    except Exception:
      pass
  return out

# ──────────────────────────────────────────────────────────────────────────────
# Heuristics: contacts, payments, keywords
# ──────────────────────────────────────────────────────────────────────────────

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
PHONE_RE = re.compile(r"(?:\+\d{1,3}\s?)?(?:\(?\d{2,4}\)?[\s\-]?)\d{3,4}[\s\-]?\d{3,4}")
KEYWORDS  = ["withdraw","recharge","unlock","frozen","VIP","commission",
             "coin","usdt","tron","erc20","binance","wallet","bonus"]

def extract_indicators(html: str) -> dict:
  if not html: return {}
  soup = BeautifulSoup(html, "html.parser")
  text = soup.get_text(" ", strip=True)
  emails = sorted(set(EMAIL_RE.findall(text)))
  phones = sorted(set(PHONE_RE.findall(text)))
  kw_hits = sorted({k for k in KEYWORDS if re.search(rf"\b{k}\b", text, re.I)})
  forms = []
  for f in soup.find_all("form"):
    act = f.get("action","")
    meth = (f.get("method","GET") or "GET").upper()
    forms.append({"action": act, "method": meth})
  links = [a.get("href") for a in soup.find_all("a", href=True)]
  pay_like = sorted({l for l in links if l and re.search(r"(recharge|deposit|withdraw|cashout|pay)", l, re.I)})
  return {"emails": emails, "phones": phones, "keywords": kw_hits,
          "forms": forms[:30], "payment_like_links": pay_like[:50]}

# ──────────────────────────────────────────────────────────────────────────────
# Playwright capture (optional)
# ──────────────────────────────────────────────────────────────────────────────

def pw_capture(urls: List[str], outdir: Path, har: bool, screens: bool,
               timeout_ms: int = 20000):
  pw_ensure()
  artifacts = outdir / "artifacts"
  ensure_dir(artifacts)
  har_path = artifacts / "session.har" if har else None
  cookies_out = artifacts / "cookies.json"
  storage_out = artifacts / "storages.json"
  screens_dir = artifacts / "screens"
  if screens: ensure_dir(screens_dir)

  from playwright.sync_api import sync_playwright

  with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    context = browser.new_context(
      record_har_path=str(har_path) if har else None,
      record_har_mode="minimal"
    )
    page = context.new_page()
    page.set_default_timeout(timeout_ms)
    storage_dump = {}

    for i, u in enumerate(urls, 1):
      page.goto(u, wait_until="load")
      if screens:
        safe = re.sub(r"[^A-Za-z0-9_.-]+","_", urlsplit(u).path or "home")
        page.screenshot(full_page=True, path=str(screens_dir/f"{i:02d}_{safe}.png"))
      storage_dump[u] = {
        "localStorage": page.evaluate("() => Object.fromEntries(Object.entries(localStorage))"),
        "sessionStorage": page.evaluate("() => Object.fromEntries(Object.entries(sessionStorage))")
      }

    cookies = context.cookies()
    (artifacts/"cookies.json").write_text(json.dumps(cookies, indent=2, ensure_ascii=False))
    (artifacts/"storages.json").write_text(json.dumps(storage_dump, indent=2, ensure_ascii=False))
    context.close()
    browser.close()


# ──────────────────────────────────────────────────────────────────────────────
# Report builder
# ──────────────────────────────────────────────────────────────────────────────

ABUSE_EMAIL_MD = """\
# Abuse Report: {domain}

**Summary:** Strong indicators of advance-fee / “task commission” scam.
Victim account shows *Frozen Balance* and withdrawal conditioned on extra
payment. Domain newly registered and fronted by Cloudflare.

- Domain: {domain}
- First seen (WHOIS): {whois_created}
- Registrar: Gname.com Pte. Ltd. (abuse: complaint@gname.com)
- Nameservers: {ns}
- Hosting/Edge: Cloudflare (abuse@cloudflare.com)
- TLS Issuer: {tls_issuer}
- Key URLs: {key_urls}

**Victim description (concise):**
- Initial payouts were made, then balance was “frozen”.
- Unlock demanded: {unlock_claim}.
- Screens/HAR and headers attached. Please investigate, disable service,
  and preserve evidence.

Attachments: headers.json, tls.json, whois.txt, rdap_domain.json,
rdap_ip.json, ct_subdomains.csv, wayback.csv, session.har (if present),
screenshots/, cookies.json, storages.json

"""

def build_report_md(dst: Path, ctx: dict) -> None:
  md = ABUSE_EMAIL_MD.format(
    domain=ctx.get("domain"),
    whois_created=ctx.get("whois_created","unknown"),
    ns=", ".join(ctx.get("ns",[])[:5]) or "n/a",
    tls_issuer=ctx.get("tls_issuer","unknown"),
    key_urls=", ".join(ctx.get("key_urls",[])[:5]) or "n/a",
    unlock_claim=ctx.get("unlock_claim","20,000 DKK unlock demand"),
  )
  (dst/"report.md").write_text(md, encoding="utf-8")

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

def main():
  ap = argparse.ArgumentParser(
    prog="osint_evidence_pack",
    description="Passive OSINT + Playwright capture to build an evidence pack.",
  )
  ap.add_argument("url", help="Target URL (scheme optional).")
  ap.add_argument("--outdir", default="evidence", help="Base output directory.")
  ap.add_argument("--limit", type=int, default=35, help="Crawl page cap (35).")
  ap.add_argument("--har", action="store_true", help="Record HAR via Playwright.")
  ap.add_argument("--screens", action="store_true", help="Full-page screenshots.")
  ap.add_argument("--browse", action="append", default=[],
                  help="Extra URLs to open (repeatable).")
  ap.add_argument("--save-wayback", action="store_true",
                  help="Ask Wayback Machine to save homepage now.")
  args = ap.parse_args()

  target = norm_url(args.url)
  host = host_from(target)
  ext = tldextract.extract(host)
  reg_domain = f"{ext.domain}.{ext.suffix}" if ext.suffix else host

  # Workspace
  stamp = dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
  base = Path(args.outdir)/f"{reg_domain}-{stamp}"
  artifacts = base/"artifacts"
  ensure_dir(artifacts)

  summary = {
    "target_input": args.url, "normalized": target, "host": host,
    "registered_domain": reg_domain, "started_utc": utc_now()
  }

  # DNS / WHOIS / RDAP / TLS
  dnsj = dns_all(reg_domain)
  (base/"dns_current.json").write_text(json.dumps(dnsj, indent=2), "utf-8")
  summary["ns"] = dnsj.get("NS",[])

  wtxt = whois_text(reg_domain) or ""
  if wtxt: (base/"whois.txt").write_text(wtxt, encoding="utf-8")
  m = re.search(r"Creation Date:\s*([0-9T:\-\.Z]+)", wtxt)
  if m: summary["whois_created"] = m.group(1)

  rd_dom = rdap_domain(reg_domain)
  if rd_dom:
    (base/"rdap_domain.json").write_text(json.dumps(rd_dom, indent=2), "utf-8")
  # Resolve first IP for IP RDAP
  ips = []
  try:
    for a in dnsj.get("A",[]): ips.append(a.split()[0])
    if not ips:
      infos = socket.getaddrinfo(host, None)
      for fam,_,_,_,sa in infos:
        if fam == socket.AF_INET: ips.append(sa[0])
  except Exception:
    pass
  if ips:
    rd_ip = rdap_ip(ips[0])
    if rd_ip:
      (base/"rdap_ip.json").write_text(json.dumps(rd_ip, indent=2), "utf-8")

  tlsj = tls_probe(host)
  (base/"tls.json").write_text(json.dumps(tlsj, indent=2), "utf-8")
  try:
    iss = tlsj.get("cert",{}).get("issuer",[])
    summary["tls_issuer"] = " / ".join([f"{k[0]}={k[1]}" for k in iss[0]]) \
                            if iss else "unknown"
  except Exception:
    pass

  # Headers + HTML of homepage
  hdr = grab_headers(target)
  (base/"headers.json").write_text(json.dumps(hdr, indent=2), "utf-8")
  html, ct = fetch_html(target)
  if html:
    (artifacts/"home.html").write_text(html, encoding="utf-8")
    ind = extract_indicators(html)
    (base/"indicators.json").write_text(json.dumps(ind, indent=2), "utf-8")
    # quick keywords presence for report context
    if "frozen" in " ".join(ind.get("keywords",[])).lower():
      summary["hint_frozen"] = True

  # Robots / sitemaps
  try:
    rtxt = requests.get(urljoin(target,"/robots.txt"), timeout=10)
    if rtxt.ok: (artifacts/"robots.txt").write_text(rtxt.text, encoding="utf-8")
    # crude sitemap autodiscovery
    sm_candidates = ["sitemap.xml","sitemap_index.xml","sitemap.php"]
    found = []
    for s in sm_candidates:
      u = urljoin(target,"/"+s)
      rs = requests.get(u, timeout=10)
      if rs.ok and rs.text.strip():
        (artifacts/f"{s}").write_text(rs.text, encoding="utf-8"); found.append(u)
    summary["sitemaps"] = found
  except Exception:
    pass

  # CT subdomains
  df_ct = ct_subdomains(reg_domain)
  if not df_ct.empty:
    df_ct.to_csv(base/"ct_subdomains.csv", index=False)

  # Wayback
  df_wb = wayback_cdx(reg_domain)
  if not df_wb.empty:
    df_wb.to_csv(base/"wayback.csv", index=False)
  if args.save_wayback:
    loc = wayback_save_now(target)
    if loc: summary["wayback_saved"] = loc

  # Shallow crawl (same-origin)
  crawled = crawl(target, limit=args.limit)
  if crawled:
    with open(base/"crawl.csv","w",newline="",encoding="utf-8") as f:
      w = csv.DictWriter(f, fieldnames=["url","status","sha256","title"])
      w.writeheader(); w.writerows(crawled)
  # Keep a few candidate “key URLs” for report
  summary["key_urls"] = [x["url"] for x in crawled[:6]]

  # Optional Playwright capture
  if args.har or args.screens or args.browse:
    urls = [target] + [u for u in args.browse if u]
    try:
      pw_capture(urls, base, args.har, args.screens)
    except SystemExit as e:
      print(str(e), file=sys.stderr)

  # Report
  build_report_md(base, {
    "domain": reg_domain,
    "whois_created": summary.get("whois_created",""),
    "ns": summary.get("ns",[]),
    "tls_issuer": summary.get("tls_issuer",""),
    "key_urls": summary.get("key_urls",[]),
    "unlock_claim": "Reported demand to pay to unlock frozen balance",
  })

  summary["finished_utc"] = utc_now()
  (base/"summary.json").write_text(json.dumps(summary, indent=2), "utf-8")
  print(json.dumps({"outdir": str(base), "summary": summary}, indent=2))

if __name__ == "__main__":
  main()
