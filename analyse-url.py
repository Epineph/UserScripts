#!/usr/bin/env python3
#  ─────────────────────────────────────────────────────────────────────────────
#  url-analysis.py — Passive URL Intelligence & Evidence Bundler (LE-ready)
#  ─────────────────────────────────────────────────────────────────────────────
"""
Passive recon only. Adds Playwright capture (HAR/screens/PDF/state) and
optional axe-core accessibility audit. Designed for evidence collection.

New CLI (Playwright / axe)
  --pw                  Enable Playwright capture (Chromium headless).
  --pw-har              Record a HAR (artifacts/session.har).
  --pw-screens          Save full-page PNG screenshots per URL.
  --pw-pdf              Save a PDF render per URL (Chromium-only).
  --pw-timeout-ms N     Navigation/action timeout (default: 20000).
  --pw-axe-js PATH      Path to axe.min.js. If provided, run axe and save
                        violations + incomplete results to artifacts/axe_*.json.

All activity is GET/HEAD/OPTIONS. No auth, no form submission, no brute force.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import email.utils
import hashlib
import ipaddress
import io
import json
import os
import re
import socket
import ssl
import sys
import os
from pathlib import Path
import textwrap
import time
import zipfile
from collections import deque
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple
from urllib.parse import urljoin, urlparse, urlsplit, urlunparse, urldefrag, \
                        parse_qs

# ──────────────────────────────────────────────────────────────────────────────
# Optional imports (graceful degradation)
# ──────────────────────────────────────────────────────────────────────────────
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
    import whois as pywhois  # type: ignore
    mods["pywhois"] = pywhois
  except Exception:
    mods["pywhois"] = None
  try:
    from bs4 import BeautifulSoup  # type: ignore
    mods["bs4"] = BeautifulSoup
  except Exception:
    mods["bs4"] = None
  # Playwright is optional
  try:
    from playwright.sync_api import sync_playwright  # type: ignore
    mods["sync_playwright"] = sync_playwright
  except Exception:
    mods["sync_playwright"] = None
  return mods

# ──────────────────────────────────────────────────────────────────────────────
# Common helpers
# ──────────────────────────────────────────────────────────────────────────────
def _utc_iso_now() -> str:
  return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

def _sha256_file(p: Path) -> str:
  h = hashlib.sha256()
  with p.open("rb") as f:
    for chunk in iter(lambda: f.read(65536), b""):
      h.update(chunk)
  return h.hexdigest()

def normalize_url(raw: str) -> str:
  raw = raw.strip()
  if not re.match(r"^[a-zA-Z][a-zA-Z0-9+\-.]*://", raw):
    return "https://" + raw
  return raw

def is_ip(host: str) -> bool:
  try:
    ipaddress.ip_address(host); return True
  except ValueError:
    return False

def _safe_fname(s: str) -> str:
  return re.sub(r"[^A-Za-z0-9._-]+", "_", s)[:120]

def _safe_host_from_url(u: str) -> Optional[str]:
  try:
    return urlparse(u).hostname
  except Exception:
    return None

def resolve_axe_js_path(cli_value: Optional[str]) -> Optional[str]:
    """
    Resolve a usable path to axe.min.js in this priority:
      1) explicit CLI value if it exists
      2) AXE_CORE_JS env var if it exists
      3) local ./node_modules/axe-core/axe.min.js
      4) Node resolver: node -p "require.resolve('axe-core/axe.min.js')"
      5) npm root -g fallback
    Returns an absolute string path or None.
    """
    def _is_file(p: Optional[str]) -> Optional[str]:
        if not p:
            return None
        q = Path(p).expanduser().resolve()
        return str(q) if q.is_file() else None

    # 1) CLI value
    found = _is_file(cli_value)
    if found:
        return found

    # 2) Environment variable
    found = _is_file(os.environ.get("AXE_CORE_JS"))
    if found:
        return found

    # 3) Local node_modules
    found = _is_file("./node_modules/axe-core/axe.min.js")
    if found:
        return found

    # 4) Node resolver
    try:
        cp = subprocess.run(
            ["node", "-p", "require.resolve('axe-core/axe.min.js')"],
            capture_output=True, text=True, timeout=3
        )
        if cp.returncode == 0:
            found = _is_file(cp.stdout.strip())
            if found:
                return found
    except Exception:
        pass

    # 5) npm root -g
    try:
        cp = subprocess.run(["npm", "root", "-g"], capture_output=True,
                            text=True, timeout=3)
        if cp.returncode == 0:
            root = cp.stdout.strip()
            found = _is_file(os.path.join(root, "axe-core", "axe.min.js"))
            if found:
                return found
    except Exception:
        pass

    return None


# ──────────────────────────────────────────────────────────────────────────────
# DNS/WHOIS/RDAP/HTTP/TLS and analyses
# (unchanged core omitted here for brevity in the header; full definitions below)
# ──────────────────────────────────────────────────────────────────────────────

# (All previously provided functions are retained: dns_query, dns_block,
#  whois_domain, rdap_domain, rdap_ip, http_probe, fetch_html, tls_probe,
#  analyze_security_headers, analyze_email_posture, probe_endpoint,
#  detect_wordpress, find_mixed_content, allowed_methods, check_sensitive_files,
#  ct_search_crtsh, wayback_samples, reverse_dns, ns_ip_map, get_robots,
#  get_sitemap, html_metadata_and_forms, third_party_hosts, light_crawl,
#  run_wappalyzer, _print_telemetry — identical to prior version.)

# -------------- BEGIN: carry-over from prior answer (FULL FUNCTIONS) ----------
# (For compactness in this snippet, assume you paste the previously supplied
#  full implementations here without alteration. Nothing else in those blocks
#  changed, except we will add Playwright and bundle wiring below.)
# -------------- END: carry-over -----------------------------------------------

# ──────────────────────────────────────────────────────────────────────────────
# Playwright capture (HAR/screens/PDF/state) + axe-core audit
# ──────────────────────────────────────────────────────────────────────────────
def _pw_capture(urls: List[str], outdir: Path, har: bool, screens: bool,
                pdf: bool, timeout_ms: int, axe_js: Optional[str],
                mods) -> Dict[str, Any]:
  """
  Passive-only page open. No clicks, no form submissions.
  Artifacts under outdir/'artifacts'.
  """
  sp = mods.get("sync_playwright")
  results: Dict[str, Any] = {"artifacts": [], "errors": []}
  if sp is None:
    results["errors"].append("Playwright not installed. pip install playwright")
    return results

  art = (outdir / "artifacts"); art.mkdir(parents=True, exist_ok=True)
  har_path = art / "session.har" if har else None
  cookies_out = art / "cookies.json"
  storage_out = art / "storages.json"

  with sp() as p:
    browser = p.chromium.launch(headless=True)
    context = browser.new_context(
      record_har_path=str(har_path) if har else None,
      record_har_mode="minimal"
    )
    context.set_default_timeout(timeout_ms)

    # Collect cookies/storage across targets
    page = context.new_page()
    for u in urls:
      try:
        page.goto(u, wait_until="domcontentloaded")
        page.wait_for_load_state("networkidle")
        ts = dt.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
        host = _safe_host_from_url(u) or "target"
        base = f"{_safe_fname(host)}_{ts}"

        if screens:
          png = art / f"{base}.png"
          page.screenshot(path=str(png), full_page=True)
          results["artifacts"].append({"path": str(png), "sha256": _sha256_file(png)})

        if pdf:
          # Chromium-only feature; requires headless. Keep defaults for A4.
          pdfp = art / f"{base}.pdf"
          try:
            page.pdf(path=str(pdfp), print_background=True)
            results["artifacts"].append({"path": str(pdfp), "sha256": _sha256_file(pdfp)})
          except Exception as e:
            results["errors"].append(f"PDF failed for {u}: {e}")

        if axe_js:
          try:
            page.add_script_tag(path=axe_js)
            # Limit scope to document to avoid heavy frame traversal.
            axe_res = page.evaluate("""async () => {
              const results = await axe.run(document, {
                resultTypes: ['violations','incomplete']
              });
              return results;
            }""")
            ap = art / f"{base}_axe.json"
            ap.write_text(json.dumps(axe_res, indent=2), encoding="utf-8")
            results["artifacts"].append({"path": str(ap), "sha256": _sha256_file(ap)})
          except Exception as e:
            results["errors"].append(f"axe-core failed for {u}: {e}")

        results.setdefault("pages", []).append({
          "url": u,
          "title": page.title(),
          "final_url": page.url,
        })
      except Exception as e:
        results["errors"].append(f"navigate {u}: {e}")

    # Persist state
    st = context.storage_state()
    storage_out.write_text(json.dumps(st, indent=2), encoding="utf-8")
    results["artifacts"].append({"path": str(storage_out), "sha256": _sha256_file(storage_out)})

    try:
      ck = context.cookies()
      cookies_out.write_text(json.dumps(ck, indent=2), encoding="utf-8")
      results["artifacts"].append({"path": str(cookies_out), "sha256": _sha256_file(cookies_out)})
    except Exception:
      pass

    context.close()
    browser.close()

  if har and har_path.exists():
    results["artifacts"].append({"path": str(har_path), "sha256": _sha256_file(har_path)})

  return results

# ──────────────────────────────────────────────────────────────────────────────
# Evidence bundle writer (extend to include Playwright artifacts)
# ──────────────────────────────────────────────────────────────────────────────
def write_bundle(report: Dict[str, Any], bundle_dir: Optional[str]) -> Optional[Dict[str, Any]]:
  if not bundle_dir:
    return None
  outdir = Path(bundle_dir).expanduser().resolve()
  outdir.mkdir(parents=True, exist_ok=True)
  manifest: Dict[str, Any] = {"created_utc": _utc_iso_now(), "files": [], "root": str(outdir)}

  # report.json
  rp = outdir / "report.json"
  rp.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
  manifest["files"].append({"path": str(rp), "sha256": _sha256_file(rp)})

  # cert, page, robots, sitemap (if present)
  tls = report.get("results", {}).get("tls") or {}
  cert = (tls.get("cert") or {})
  if cert.get("pem"):
    pem_p = outdir / "cert.pem"
    pem_p.write_text(cert["pem"], encoding="ascii")
    manifest["files"].append({"path": str(pem_p), "sha256": _sha256_file(pem_p)})

  html_info = report.get("results", {}).get("page_fetch_raw") or {}
  if html_info.get("text"):
    html_p = outdir / "page.html"
    html_p.write_text(html_info["text"], encoding="utf-8", errors="replace")
    manifest["files"].append({"path": str(html_p), "sha256": _sha256_file(html_p)})

  rob = report.get("results", {}).get("robots") or {}
  if rob.get("text_sample"):
    rb = outdir / "robots.txt"
    rb.write_text(rob["text_sample"], encoding="utf-8")
    manifest["files"].append({"path": str(rb), "sha256": _sha256_file(rb)})

  sm = report.get("results", {}).get("sitemap") or {}
  if sm.get("xml_sample"):
    sp = outdir / "sitemap.xml"
    sp.write_text(sm["xml_sample"], encoding="utf-8")
    manifest["files"].append({"path": str(sp), "sha256": _sha256_file(sp)})

  # Include Playwright artifacts if we created any inside bundle_dir
  pw = report.get("results", {}).get("playwright") or {}
  for a in pw.get("artifacts", []):
    p = Path(a["path"])
    # If artifacts already live under bundle_dir, just hash and add;
    # if not, copy them next to other artifacts (rare).
    try:
      if not str(p).startswith(str(outdir)):
        dest = outdir / "artifacts" / p.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(Path(p).read_bytes())
        p = dest
      manifest["files"].append({"path": str(p), "sha256": _sha256_file(p)})
    except Exception:
      pass

  mf = outdir / "manifest.json"
  mf.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
  return {"dir": str(outdir), "manifest": manifest}

def zip_bundle(bundle_dir: str, zip_name: Optional[str]) -> Optional[str]:
  folder = Path(bundle_dir).resolve()
  zpath = Path(zip_name).resolve() if zip_name else folder.with_suffix(".zip")
  with zipfile.ZipFile(zpath, "w", compression=zipfile.ZIP_DEFLATED) as z:
    for p in folder.rglob("*"):
      if p.is_file():
        z.write(p, p.relative_to(folder))
  return str(zpath)

# ──────────────────────────────────────────────────────────────────────────────
# CLI wiring
# ──────────────────────────────────────────────────────────────────────────────
def build_arg_parser() -> argparse.ArgumentParser:
  epilog = r"""
EXAMPLES
  Evidence + Playwright (HAR/screens/PDF/axe)
    url-analysis https://example.com \
      --bundle evidence_example --zip-bundle --save-html --save-cert \
      --pw --pw-har --pw-screens --pw-pdf --pw-axe-js ./node_modules/axe-core/axe.min.js

  Minimal Playwright evidence
    url-analysis example.com --bundle ev --pw --pw-har --pw-screens
"""
  p = argparse.ArgumentParser(
    prog="url-analysis",
    description=("Passive URL intelligence + evidence bundle. Optional "
                 "Playwright capture (HAR/screens/PDF/state) and axe-core audit."),
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=epilog,
  )
  p.add_argument("url", help="Target URL/host (scheme optional; https assumed).")
  p.add_argument("--out", metavar="FILE", help="Write full JSON report to FILE.")
  p.add_argument("--bundle", metavar="DIR", help="Write artifacts to DIR + manifest.")
  p.add_argument("--zip-bundle", action="store_true", help="ZIP the bundle directory.")
  p.add_argument("-T", "--timeout", type=float, default=15.0, help="Network timeout (s).")
  p.add_argument("-A", "--user-agent", default="url-analysis/3.1 (+local use)",
                 help="HTTP User-Agent.")

  # Toggles from prior version (kept)
  p.add_argument("--no-dns", action="store_true"); p.add_argument("--no-whois", action="store_true")
  p.add_argument("--no-rdap", action="store_true"); p.add_argument("--no-http", action="store_true")
  p.add_argument("--no-tls", action="store_true"); p.add_argument("--no-geo", action="store_true")
  p.add_argument("--no-wappalyzer", dest="no_wappalyzer", action="store_true")
  p.add_argument("--no-vuln", action="store_true")
  p.add_argument("--ct", action="store_true"); p.add_argument("--wayback", action="store_true")
  p.add_argument("--reverse-dns", action="store_true"); p.add_argument("--ns-ips", action="store_true")
  p.add_argument("--save-html", action="store_true"); p.add_argument("--save-cert", action="store_true")
  p.add_argument("--robots", action="store_true"); p.add_argument("--sitemap", action="store_true")
  p.add_argument("--crawl", type=int, default=0)
  p.add_argument("--telemetry", action="store_true")

  # New: Playwright/axe
  p.add_argument("--pw", action="store_true", help="Enable Playwright capture.")
  p.add_argument("--pw-har", action="store_true", help="Record HAR in artifacts/.")
  p.add_argument("--pw-screens", action="store_true", help="Save full-page PNG screenshots.")
  p.add_argument("--pw-pdf", action="store_true", help="Save a Chromium PDF render.")
  p.add_argument("--pw-timeout-ms", type=int, default=20000, help="PW timeout (ms).")
  p.add_argument("--pw-axe-js", metavar="PATH", default=None,
                 help="Path to axe.min.js (from npm 'axe-core'). Enables axe audit.")
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
      "dns": not args.no_dns, "whois": not args.no_whois, "rdap": not args.no_rdap,
      "http": not args.no_http, "tls": not args.no_tls, "geo": not args.no_geo,
      "wappalyzer": not args.no_wappalyzer, "vuln": not args.no_vuln,
      "ct": args.ct, "wayback": args.wayback, "reverse_dns": args.reverse_dns,
      "ns_ips": args.ns_ips, "crawl": bool(args.crawl), "playwright": args.pw,
    },
    "results": {}, "errors": {},
  }

  # ----- Core pipeline (identical to prior version) -----
  # Paste the previously supplied full implementations here (DNS/WHOIS/RDAP/HTTP/
  # TLS/Wappalyzer/robots/sitemap/fetch_html/vuln/html_meta/ct/wayback/ns map/
  # crawl/age heuristics), storing results in report[...] and errors in report["errors"].

  # For brevity in this snippet, we assume those blocks are present unchanged.
  # ------------------------------------------------------

  # Playwright capture (optional)
  if args.pw:
    try:
      if args.bundle:
        outdir = Path(args.bundle).expanduser().resolve()
      else:
        outdir = Path("pw_artifacts").resolve()
        outdir.mkdir(parents=True, exist_ok=True)
      target_urls = [ (report.get("results", {}).get("http", {}).get("final_url") or url) ]
      pwres = _pw_capture(
        urls=target_urls, outdir=outdir,
        har=args.pw_har, screens=args.pw_screens, pdf=args.pw_pdf,
        timeout_ms=args.pw_timeout_ms, axe_js=args.pw_axe_js, mods=mods
      )
      report.setdefault("results", {})["playwright"] = pwres
    except Exception as e:
      report["errors"]["playwright"] = str(e)

  report["timestamps"]["finished_utc"] = _utc_iso_now()

  if args.telemetry:
    try:
      _print_telemetry(report)
    except Exception:
      pass

  # Output
  j = json.dumps(report, indent=2, ensure_ascii=False)
  print(j)
  if args.out:
    try:
      Path(args.out).write_text(j, encoding="utf-8")
    except Exception as e:
      print(f"WARNING: failed to write --out file: {e}", file=sys.stderr)

  # Bundle & zip
  if args.bundle:
    try:
      b = write_bundle(report, args.bundle)
      if args.zip_bundle and b:
        z = zip_bundle(args.bundle, None)
        print(f"# Bundle ZIP: {z}", file=sys.stderr)
    except Exception as e:
      print(f"WARNING: failed to write bundle: {e}", file=sys.stderr)

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

