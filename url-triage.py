#!/usr/bin/env python3
"""
url_triage_combined.py

Combined static + dynamic URL triage scanner in pure Python.

What it does
------------
- Normalizes and inspects a URL.
- Performs static fetch analysis with requests.
- Performs dynamic browser analysis with Playwright Chromium.
- Inspects:
  * query parameters
  * redirects
  * TLS certificate summary
  * forms / password fields / cross-domain posting
  * meta refresh
  * visible suspicious text
  * network requests / responses
  * downloads attempted
  * console errors and page errors
- Optionally enriches with:
  * Google Safe Browsing
  * VirusTotal URL report

What it does NOT do
-------------------
- It does not prove safety.
- It does not safely detonate attachments.
- It does not replace browser patching, EDR, or proper sandboxing.

Environment variables
---------------------
- SAFE_BROWSING_API_KEY
- VT_API_KEY

Examples
--------
1) Basic:
   ./url_triage_combined.py "https://example.org"

2) Verbose:
   ./url_triage_combined.py "https://example.org" --verbose

3) Save JSON:
   ./url_triage_combined.py "https://example.org" --json-out report.json

4) Longer dynamic observation:
   ./url_triage_combined.py "https://example.org" --wait-ms 8000

5) Disable dynamic stage:
   ./url_triage_combined.py "https://example.org" --no-dynamic

6) JSON to stdout:
   ./url_triage_combined.py "https://example.org" --json

7) Real suspicious link:
   ./url_triage_combined.py \
     "https://www.intechopen.com/welcome/1005690?call_email=x@y.z&src=S-F-2-HST&r=2"
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import os
import re
import socket
import ssl
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from html import unescape
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, quote, urljoin, urlparse, urlunparse

import idna
import requests
import tldextract
from bs4 import BeautifulSoup
from playwright.async_api import async_playwright


# =============================================================================
# Constants
# =============================================================================

DEFAULT_TIMEOUT = 12
DEFAULT_WAIT_MS = 5000

USER_AGENT = (
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
  "(KHTML, like Gecko) Chrome/146.0 Safari/537.36"
)

SUSPICIOUS_QUERY_KEYS = {
  "email", "mail", "user", "username", "login", "account",
  "token", "code", "key", "auth", "password", "passwd",
  "session", "sid", "redirect", "return", "continue",
  "next", "callback", "dest", "destination"
}

TRACKING_PARAM_KEYS = {
  "utm_source", "utm_medium", "utm_campaign", "utm_term",
  "utm_content", "src", "ref", "r", "cid", "eid", "mid"
}

SUSPICIOUS_TEXT_PATTERNS = [
  r"\bverify\s+your\s+account\b",
  r"\bconfirm\s+your\s+identity\b",
  r"\breset\s+your\s+password\b",
  r"\bpayment\s+failed\b",
  r"\bupdate\s+payment\b",
  r"\bsecurity\s+alert\b",
  r"\bunusual\s+sign[- ]?in\b",
  r"\byour\s+mailbox\s+will\s+be\s+disabled\b",
  r"\bclick\s+here\s+to\s+avoid\b",
  r"\burgent\s+action\s+required\b",
]

PASSWORD_FIELD_NAMES = {"password", "passwd", "pass", "pwd"}

LIKELY_BRAND_KEYWORDS = {
  "microsoft", "office", "outlook", "gmail", "google",
  "apple", "amazon", "paypal", "dhl", "fedex", "bank",
  "mitid", "netflix", "dropbox"
}


# =============================================================================
# Data models
# =============================================================================

@dataclass
class Finding:
  severity: str
  points: int
  category: str
  message: str


@dataclass
class CertSummary:
  subject_cn: Optional[str] = None
  san_dns: List[str] = field(default_factory=list)
  issuer: Optional[str] = None
  not_before: Optional[str] = None
  not_after: Optional[str] = None
  days_remaining: Optional[int] = None
  error: Optional[str] = None


@dataclass
class ScanResult:
  requested_url: str
  normalized_url: str
  hostname: Optional[str] = None
  registered_domain: Optional[str] = None
  ip_addresses: List[str] = field(default_factory=list)

  fetched: bool = False
  final_url: Optional[str] = None
  http_status: Optional[int] = None
  redirect_chain: List[str] = field(default_factory=list)
  tls: Optional[CertSummary] = None
  content_type: Optional[str] = None
  content_length: Optional[int] = None
  title: Optional[str] = None

  forms_count: int = 0
  external_scripts: List[str] = field(default_factory=list)
  external_iframes: List[str] = field(default_factory=list)
  suspicious_params: Dict[str, List[str]] = field(default_factory=dict)
  tracking_params: Dict[str, List[str]] = field(default_factory=dict)

  dynamic_enabled: bool = False
  dynamic_final_url: Optional[str] = None
  dynamic_title: Optional[str] = None
  dynamic_requests: List[Dict[str, Any]] = field(default_factory=list)
  dynamic_responses: List[Dict[str, Any]] = field(default_factory=list)
  dynamic_redirects: List[Dict[str, Any]] = field(default_factory=list)
  dynamic_console: List[Dict[str, Any]] = field(default_factory=list)
  dynamic_page_errors: List[str] = field(default_factory=list)
  dynamic_downloads: List[str] = field(default_factory=list)
  dynamic_forms: List[Dict[str, Any]] = field(default_factory=list)
  dynamic_meta_refresh: List[Dict[str, str]] = field(default_factory=list)

  safe_browsing: Optional[Dict[str, Any]] = None
  virustotal: Optional[Dict[str, Any]] = None

  findings: List[Finding] = field(default_factory=list)
  score: int = 0
  verdict: str = "unknown"
  errors: List[str] = field(default_factory=list)

  artifacts: Dict[str, str] = field(default_factory=dict)


# =============================================================================
# Utility functions
# =============================================================================

def functionEprint(*args: Any, **kwargs: Any) -> None:
  print(*args, file=sys.stderr, **kwargs)


def functionNormalizeUrl(url: str) -> str:
  url = url.strip()
  if not url:
    raise ValueError("empty URL")

  parsed = urlparse(url)
  if not parsed.scheme:
    url = "https://" + url
    parsed = urlparse(url)

  if parsed.scheme not in {"http", "https"}:
    raise ValueError(f"unsupported scheme: {parsed.scheme}")

  if not parsed.netloc:
    raise ValueError("URL has no hostname")

  return urlunparse(parsed)


def functionIsIpLiteral(hostname: str) -> bool:
  try:
    socket.inet_aton(hostname)
    return True
  except OSError:
    pass

  try:
    socket.inet_pton(socket.AF_INET6, hostname)
    return True
  except OSError:
    return False


def functionDecodeHostname(hostname: str) -> Tuple[str, Optional[str]]:
  try:
    ascii_host = idna.encode(hostname).decode("ascii")
    unicode_host = idna.decode(ascii_host.encode("ascii"))
    return ascii_host, unicode_host
  except Exception:
    return hostname, None


def functionRegisteredDomain(hostname: str) -> str:
  ext = tldextract.extract(hostname)
  if ext.domain and ext.suffix:
    return f"{ext.domain}.{ext.suffix}"
  return hostname


def functionResolveIps(hostname: str) -> List[str]:
  ips: List[str] = []
  try:
    infos = socket.getaddrinfo(hostname, None)
    seen = set()
    for info in infos:
      ip = info[4][0]
      if ip not in seen:
        seen.add(ip)
        ips.append(ip)
  except socket.gaierror:
    pass
  return ips


def functionExtractQueryFlags(
  url: str
) -> Tuple[Dict[str, List[str]], Dict[str, List[str]]]:
  parsed = urlparse(url)
  params = parse_qs(parsed.query, keep_blank_values=True)

  suspicious: Dict[str, List[str]] = {}
  tracking: Dict[str, List[str]] = {}

  for key, values in params.items():
    key_l = key.lower()
    if key_l in SUSPICIOUS_QUERY_KEYS:
      suspicious[key] = values
    if key_l in TRACKING_PARAM_KEYS:
      tracking[key] = values

  return suspicious, tracking


def functionGetTlsSummary(
  hostname: str,
  port: int = 443,
  timeout: int = DEFAULT_TIMEOUT
) -> CertSummary:
  summary = CertSummary()
  try:
    context = ssl.create_default_context()
    with socket.create_connection((hostname, port), timeout=timeout) as sock:
      with context.wrap_socket(sock, server_hostname=hostname) as ssock:
        cert = ssock.getpeercert()

    subject = cert.get("subject", [])
    issuer = cert.get("issuer", [])

    for item in subject:
      for k, v in item:
        if k == "commonName":
          summary.subject_cn = v
          break

    dns_names = []
    for item in cert.get("subjectAltName", []):
      if len(item) == 2 and item[0] == "DNS":
        dns_names.append(item[1])
    summary.san_dns = dns_names

    issuer_parts = []
    for item in issuer:
      for k, v in item:
        issuer_parts.append(f"{k}={v}")
    if issuer_parts:
      summary.issuer = ", ".join(issuer_parts)

    nb = cert.get("notBefore")
    na = cert.get("notAfter")
    if nb:
      dt_nb = datetime.strptime(nb, "%b %d %H:%M:%S %Y %Z")
      summary.not_before = dt_nb.replace(
        tzinfo=timezone.utc
      ).isoformat()
    if na:
      dt_na = datetime.strptime(na, "%b %d %H:%M:%S %Y %Z")
      dt_na = dt_na.replace(tzinfo=timezone.utc)
      summary.not_after = dt_na.isoformat()
      summary.days_remaining = (
        dt_na - datetime.now(timezone.utc)
      ).days

  except Exception as exc:
    summary.error = str(exc)

  return summary


def functionAddFinding(
  result: ScanResult,
  severity: str,
  points: int,
  category: str,
  message: str
) -> None:
  result.findings.append(
    Finding(
      severity=severity,
      points=points,
      category=category,
      message=message,
    )
  )
  result.score += points


def functionVerdictFromScore(score: int) -> str:
  if score >= 70:
    return "high-risk"
  if score >= 35:
    return "moderate-risk"
  if score >= 15:
    return "low-to-moderate-risk"
  return "low-risk"


def functionHostOf(url: str) -> str:
  return urlparse(url).hostname or ""


def functionSchemeOf(url: str) -> str:
  return urlparse(url).scheme or ""


def functionLooksLikeLoginForm(form: Any) -> bool:
  inputs = form.find_all("input")
  kinds = []
  names = []

  for inp in inputs:
    t = (inp.get("type") or "text").strip().lower()
    n = (inp.get("name") or "").strip().lower()
    kinds.append(t)
    names.append(n)

  has_password = "password" in kinds
  has_email_like = any(x in {"email", "text"} for x in kinds) or any(
    any(k in n for k in ("email", "user", "login", "account"))
    for n in names
  )
  return has_password or (has_email_like and len(inputs) >= 2)


# =============================================================================
# Static stage
# =============================================================================

def functionAnalyzeUrlStructure(result: ScanResult, normalized_url: str) -> None:
  parsed = urlparse(normalized_url)
  hostname = parsed.hostname or ""
  ascii_host, unicode_host = functionDecodeHostname(hostname)

  result.hostname = ascii_host
  result.registered_domain = functionRegisteredDomain(ascii_host)

  if unicode_host and unicode_host != ascii_host:
    functionAddFinding(
      result, "medium", 10, "url",
      f"Hostname uses IDN/punycode-capable representation: "
      f"{ascii_host} / {unicode_host}"
    )

  if functionIsIpLiteral(ascii_host):
    functionAddFinding(
      result, "high", 20, "url",
      "URL uses IP literal instead of domain name."
    )

  if "@" in parsed.netloc:
    functionAddFinding(
      result, "high", 20, "url",
      "URL contains '@' in authority component."
    )

  suspicious_params, tracking_params = functionExtractQueryFlags(normalized_url)
  result.suspicious_params = suspicious_params
  result.tracking_params = tracking_params

  if suspicious_params:
    shown = ", ".join(sorted(suspicious_params.keys()))
    functionAddFinding(
      result, "medium", 6, "url",
      f"Sensitive/suspicious query parameters present: {shown}"
    )

  if tracking_params:
    shown = ", ".join(sorted(tracking_params.keys()))
    functionAddFinding(
      result, "low", 1, "url",
      f"Tracking/campaign parameters present: {shown}"
    )

  if parsed.scheme != "https":
    functionAddFinding(
      result, "medium", 10, "url",
      "URL is not HTTPS."
    )

  result.ip_addresses = functionResolveIps(ascii_host)


def functionFetchUrl(
  url: str,
  timeout: int,
  follow_redirects: bool
) -> requests.Response:
  session = requests.Session()
  session.headers.update({"User-Agent": USER_AGENT})
  return session.get(
    url,
    timeout=timeout,
    allow_redirects=follow_redirects,
    stream=False,
  )


def functionAnalyzeHtml(
  result: ScanResult,
  html: str,
  base_url: str,
  do_text_analysis: bool
) -> None:
  soup = BeautifulSoup(html, "html.parser")

  if soup.title and soup.title.string:
    result.title = soup.title.string.strip()

  forms = soup.find_all("form")
  result.forms_count = len(forms)

  final_host = functionHostOf(base_url)
  final_scheme = functionSchemeOf(base_url)
  final_regdom = (
    functionRegisteredDomain(final_host) if final_host else ""
  )

  for idx, form in enumerate(forms, start=1):
    action = (form.get("action") or "").strip()
    method = (form.get("method") or "GET").upper()
    full_action = urljoin(base_url, action) if action else base_url
    action_host = functionHostOf(full_action)
    action_scheme = functionSchemeOf(full_action)
    action_regdom = (
      functionRegisteredDomain(action_host) if action_host else final_regdom
    )

    if functionLooksLikeLoginForm(form):
      functionAddFinding(
        result, "medium", 8, "html",
        f"Form #{idx} looks login-like "
        f"(method={method}, action_host={action_host or final_host})."
      )

    if action_scheme == "http" and final_scheme == "https":
      functionAddFinding(
        result, "high", 20, "html",
        f"Form #{idx} posts from HTTPS page to insecure HTTP target."
      )

    if action_host and action_regdom != final_regdom:
      functionAddFinding(
        result, "high", 18, "html",
        f"Form #{idx} submits to different registered domain: "
        f"{action_regdom} (page is {final_regdom})."
      )

    hidden_pw = False
    for inp in form.find_all("input"):
      typ = (inp.get("type") or "text").strip().lower()
      name = (inp.get("name") or "").strip().lower()
      if typ == "hidden" and any(k in name for k in PASSWORD_FIELD_NAMES):
        hidden_pw = True

    if hidden_pw:
      functionAddFinding(
        result, "high", 20, "html",
        f"Form #{idx} contains hidden input suggesting password handling."
      )

  for script in soup.find_all("script", src=True):
    src = urljoin(base_url, script["src"])
    result.external_scripts.append(src)
    if functionHostOf(src):
      script_reg = functionRegisteredDomain(functionHostOf(src))
      if script_reg != final_regdom:
        functionAddFinding(
          result, "low", 1, "html",
          f"External script loaded from different registered domain: {src}"
        )

  for iframe in soup.find_all("iframe", src=True):
    src = urljoin(base_url, iframe["src"])
    result.external_iframes.append(src)
    functionAddFinding(
      result, "medium", 5, "html",
      f"Iframe present: {src}"
    )

  meta_refresh = soup.find_all("meta", attrs={"http-equiv": True})
  for node in meta_refresh:
    http_equiv = (node.get("http-equiv") or "").strip().lower()
    content = (node.get("content") or "").strip()
    if http_equiv == "refresh":
      functionAddFinding(
        result, "medium", 6, "html",
        f"Meta refresh present: {content}"
      )

  if do_text_analysis:
    visible_text = " ".join(soup.stripped_strings)
    visible_text = unescape(visible_text)
    text_l = visible_text.lower()

    for pat in SUSPICIOUS_TEXT_PATTERNS:
      if re.search(pat, text_l, flags=re.IGNORECASE):
        functionAddFinding(
          result, "medium", 4, "text",
          f"Suspicious page text matched pattern: {pat}"
        )

    brand_hits = {kw for kw in LIKELY_BRAND_KEYWORDS if kw in text_l}
    if len(brand_hits) >= 2:
      functionAddFinding(
        result, "low", 2, "text",
        "Page text references multiple common brand/security keywords: "
        + ", ".join(sorted(brand_hits))
      )


def functionAnalyzeResponse(
  result: ScanResult,
  resp: requests.Response,
  timeout: int,
  do_text_analysis: bool
) -> None:
  result.fetched = True
  result.final_url = resp.url
  result.http_status = resp.status_code
  result.redirect_chain = [r.url for r in resp.history] + [resp.url]
  result.content_type = resp.headers.get("Content-Type")
  result.content_length = len(resp.content or b"")

  if len(resp.history) >= 3:
    functionAddFinding(
      result, "medium", 8, "network",
      f"Long redirect chain ({len(resp.history)} redirects)."
    )

  if resp.status_code >= 400:
    functionAddFinding(
      result, "low", 2, "network",
      f"HTTP status {resp.status_code}."
    )

  final_host = functionHostOf(resp.url)
  final_regdom = functionRegisteredDomain(final_host) if final_host else ""

  if result.registered_domain and final_regdom:
    if final_regdom != result.registered_domain:
      functionAddFinding(
        result, "high", 18, "network",
        f"Final registered domain differs from original: "
        f"{result.registered_domain} -> {final_regdom}"
      )

  if functionSchemeOf(resp.url) == "https" and final_host:
    result.tls = functionGetTlsSummary(final_host, timeout=timeout)
    if result.tls.error:
      functionAddFinding(
        result, "low", 2, "tls",
        f"TLS summary unavailable: {result.tls.error}"
      )
    else:
      if result.tls.days_remaining is not None:
        if result.tls.days_remaining < 0:
          functionAddFinding(
            result, "high", 25, "tls",
            "TLS certificate appears expired."
          )
        elif result.tls.days_remaining < 7:
          functionAddFinding(
            result, "medium", 8, "tls",
            "TLS certificate expires very soon."
          )

  ctype = (result.content_type or "").lower()
  if "text/html" in ctype:
    functionAnalyzeHtml(result, resp.text, resp.url, do_text_analysis)
  else:
    functionAddFinding(
      result, "low", 1, "content",
      f"Content-Type is not HTML: {result.content_type!r}"
    )


# =============================================================================
# Reputation APIs
# =============================================================================

def functionVtUrlId(url: str) -> str:
  return base64.urlsafe_b64encode(url.encode()).decode().strip("=")


def functionCheckGoogleSafeBrowsing(
  url: str,
  api_key: str,
  timeout: int
) -> Dict[str, Any]:
  endpoint = (
    "https://safebrowsing.googleapis.com/v4/threatMatches:find"
    f"?key={quote(api_key)}"
  )
  payload = {
    "client": {
      "clientId": "local-url-triage-combined",
      "clientVersion": "1.0.0"
    },
    "threatInfo": {
      "threatTypes": [
        "MALWARE",
        "SOCIAL_ENGINEERING",
        "UNWANTED_SOFTWARE",
        "POTENTIALLY_HARMFUL_APPLICATION"
      ],
      "platformTypes": ["ANY_PLATFORM"],
      "threatEntryTypes": ["URL"],
      "threatEntries": [{"url": url}]
    }
  }

  resp = requests.post(endpoint, json=payload, timeout=timeout)
  resp.raise_for_status()
  return resp.json()


def functionVtGetUrlReport(
  url: str,
  api_key: str,
  timeout: int
) -> Dict[str, Any]:
  url_id = functionVtUrlId(url)
  resp = requests.get(
    f"https://www.virustotal.com/api/v3/urls/{url_id}",
    headers={"x-apikey": api_key},
    timeout=timeout,
  )
  if resp.status_code == 404:
    return {"error": "URL not present in VirusTotal dataset yet"}
  resp.raise_for_status()
  return resp.json()


# =============================================================================
# Dynamic Playwright stage
# =============================================================================

async def functionRunDynamicStage(
  result: ScanResult,
  output_dir: Path,
  timeout: int,
  wait_ms: int,
  save_screenshot: bool,
  save_html: bool,
  headed: bool
) -> None:
  result.dynamic_enabled = True

  async with async_playwright() as p:
    browser = await p.chromium.launch(headless=not headed)
    context = await browser.new_context(
      user_agent=USER_AGENT,
      ignore_https_errors=False,
      java_script_enabled=True,
      viewport={"width": 1440, "height": 1200},
      accept_downloads=False,
    )

    context.set_default_timeout(timeout * 1000)
    context.set_default_navigation_timeout(timeout * 1000)

    async def route_handler(route: Any) -> None:
      request = route.request
      url = request.url
      resource_type = request.resource_type
      if url.startswith(("data:", "blob:")):
        await route.continue_()
        return
      if resource_type == "media":
        await route.abort()
        return
      await route.continue_()

    await context.route("**/*", route_handler)

    page = await context.new_page()

    page.on(
      "console",
      lambda msg: result.dynamic_console.append({
        "type": msg.type,
        "text": msg.text
      })
    )
    page.on(
      "pageerror",
      lambda exc: result.dynamic_page_errors.append(str(exc))
    )
    page.on(
      "download",
      lambda dl: result.dynamic_downloads.append(dl.suggested_filename)
    )

    def on_request(request: Any) -> None:
      prev = request.redirected_from
      rec = {
        "url": request.url,
        "method": request.method,
        "resource_type": request.resource_type,
        "is_navigation_request": request.is_navigation_request(),
        "frame_url": request.frame.url if request.frame else None,
        "redirected_from": prev.url if prev else None,
      }
      result.dynamic_requests.append(rec)
      if prev:
        result.dynamic_redirects.append({
          "from": prev.url,
          "to": request.url,
        })

    async def on_response(response: Any) -> None:
      req = response.request
      result.dynamic_responses.append({
        "url": response.url,
        "status": response.status,
        "resource_type": req.resource_type,
      })

    page.on("request", on_request)
    page.on("response", lambda response: asyncio.create_task(
      on_response(response)
    ))

    goto_response = None
    try:
      goto_response = await page.goto(
        result.normalized_url,
        wait_until="domcontentloaded"
      )
    except Exception as exc:
      result.errors.append(f"Dynamic navigation error: {exc}")

    if wait_ms > 0:
      await page.wait_for_timeout(wait_ms)

    result.dynamic_final_url = page.url
    if goto_response and result.http_status is None:
      result.http_status = goto_response.status

    if result.dynamic_redirects and len(result.dynamic_redirects) >= 3:
      functionAddFinding(
        result, "medium", 8, "dynamic-network",
        f"Long redirect chain detected dynamically "
        f"({len(result.dynamic_redirects)})."
      )

    original_reg = functionRegisteredDomain(
      functionHostOf(result.normalized_url)
    )
    final_reg = functionRegisteredDomain(functionHostOf(page.url))
    if original_reg and final_reg and original_reg != final_reg:
      functionAddFinding(
        result, "high", 18, "dynamic-network",
        f"Dynamic final registered domain differs from original: "
        f"{original_reg} -> {final_reg}"
      )

    dom = await page.evaluate(
      """
      () => {
        const forms = Array.from(document.forms).map((form, index) => {
          const action = form.getAttribute('action') || '';
          const method = (form.getAttribute('method') || 'GET').toUpperCase();
          const inputs = Array.from(form.querySelectorAll('input')).map(inp => ({
            type: (inp.getAttribute('type') || 'text').toLowerCase(),
            name: inp.getAttribute('name') || '',
            autocomplete: inp.getAttribute('autocomplete') || '',
            hidden: (inp.getAttribute('type') || '').toLowerCase() === 'hidden'
          }));
          let actionUrl = '';
          try {
            actionUrl = new URL(
              action || window.location.href,
              window.location.href
            ).toString();
          } catch (_) {
            actionUrl = '';
          }

          return {
            index: index + 1,
            method,
            action,
            actionUrl,
            passwordFields: inputs.filter(x => x.type === 'password').length,
            inputCount: inputs.length,
            inputs
          };
        });

        const scripts = Array.from(document.querySelectorAll('script[src]'))
          .map(x => x.src)
          .filter(Boolean);

        const iframes = Array.from(document.querySelectorAll('iframe[src]'))
          .map(x => x.src)
          .filter(Boolean);

        const metaRefresh = Array.from(
          document.querySelectorAll('meta[http-equiv]')
        ).map(node => ({
          httpEquiv: node.getAttribute('http-equiv') || '',
          content: node.getAttribute('content') || ''
        }));

        const text = document.body ? (document.body.innerText || '') : '';

        return {
          title: document.title || '',
          url: window.location.href,
          hostname: window.location.hostname,
          forms,
          scripts,
          iframes,
          metaRefresh,
          text
        };
      }
      """
    )

    result.dynamic_title = dom["title"]
    result.dynamic_forms = dom["forms"]
    result.dynamic_meta_refresh = dom["metaRefresh"]

    if dom["title"] and not result.title:
      result.title = dom["title"]

    if dom["forms"]:
      functionAddFinding(
        result, "low", 2, "dynamic-html",
        f"Dynamic DOM contains {len(dom['forms'])} form(s)."
      )

    page_reg = functionRegisteredDomain(dom["hostname"])

    for form in dom["forms"]:
      action_url = form.get("actionUrl") or dom["url"]
      action_host = functionHostOf(action_url)
      action_reg = functionRegisteredDomain(action_host)

      if form.get("passwordFields", 0) > 0:
        functionAddFinding(
          result, "medium", 8, "dynamic-html",
          f"Form #{form['index']} contains "
          f"{form['passwordFields']} password field(s)."
        )

      if (
        functionSchemeOf(action_url) == "http"
        and functionSchemeOf(dom["url"]) == "https"
      ):
        functionAddFinding(
          result, "high", 20, "dynamic-html",
          f"Form #{form['index']} posts from HTTPS page to HTTP target."
        )

      if action_host and action_reg and page_reg and action_reg != page_reg:
        functionAddFinding(
          result, "high", 18, "dynamic-html",
          f"Form #{form['index']} submits to different registered domain "
          f"({action_reg} vs {page_reg})."
        )

      hidden_cred = any(
        inp.get("hidden") and re.search(
          r"pass|pwd|token|auth", inp.get("name", ""), re.I
        )
        for inp in form.get("inputs", [])
      )
      if hidden_cred:
        functionAddFinding(
          result, "high", 16, "dynamic-html",
          f"Form #{form['index']} has hidden credential-like field(s)."
        )

    for entry in dom["metaRefresh"]:
      if re.search(r"refresh", entry.get("httpEquiv", ""), re.I):
        functionAddFinding(
          result, "medium", 6, "dynamic-html",
          f"Meta refresh present: {entry.get('content', '')}"
        )

    for src in dom["scripts"]:
      result.external_scripts.append(src)
      script_reg = functionRegisteredDomain(functionHostOf(src))
      if script_reg and script_reg != page_reg:
        functionAddFinding(
          result, "low", 1, "dynamic-html",
          f"External script from different registered domain: {src}"
        )

    for src in dom["iframes"]:
      result.external_iframes.append(src)
      functionAddFinding(
        result, "medium", 5, "dynamic-html",
        f"Iframe present dynamically: {src}"
      )

    visible_text = unescape(dom["text"] or "")
    for pat in SUSPICIOUS_TEXT_PATTERNS:
      if re.search(pat, visible_text, re.I):
        functionAddFinding(
          result, "medium", 4, "dynamic-text",
          f"Visible text matched suspicious pattern: {pat}"
        )

    if result.dynamic_console:
      severe = [
        x for x in result.dynamic_console
        if str(x.get("type", "")).lower() in {"error", "warning"}
      ]
      if severe:
        functionAddFinding(
          result, "low", 2, "dynamic-runtime",
          f"Console emitted {len(severe)} warning/error message(s)."
        )

    if result.dynamic_page_errors:
      functionAddFinding(
        result, "low", 2, "dynamic-runtime",
        f"Page produced {len(result.dynamic_page_errors)} script error(s)."
      )

    if result.dynamic_downloads:
      functionAddFinding(
        result, "high", 20, "dynamic-runtime",
        f"Page attempted {len(result.dynamic_downloads)} download(s)."
      )

    if save_screenshot:
      screenshot_path = output_dir / "screenshot.png"
      try:
        await page.screenshot(path=str(screenshot_path), full_page=True)
        result.artifacts["screenshot"] = str(screenshot_path)
      except Exception as exc:
        result.errors.append(f"Dynamic screenshot failed: {exc}")

    if save_html:
      html_path = output_dir / "dynamic_final_dom.html"
      try:
        html = await page.content()
        html_path.write_text(html, encoding="utf-8")
        result.artifacts["dynamic_final_html"] = str(html_path)
      except Exception as exc:
        result.errors.append(f"Dynamic HTML snapshot failed: {exc}")

    await context.close()
    await browser.close()


# =============================================================================
# Orchestration
# =============================================================================

def functionEnrichWithSafeBrowsing(result: ScanResult, timeout: int) -> None:
  api_key = os.environ.get("SAFE_BROWSING_API_KEY")
  if not api_key:
    return

  target_url = result.dynamic_final_url or result.final_url or result.normalized_url

  try:
    data = functionCheckGoogleSafeBrowsing(target_url, api_key, timeout)
    result.safe_browsing = data
    matches = data.get("matches", [])
    if matches:
      functionAddFinding(
        result, "high", 50, "reputation",
        f"Google Safe Browsing matched {len(matches)} threat record(s)."
      )
  except Exception as exc:
    result.errors.append(f"Safe Browsing check failed: {exc}")


def functionEnrichWithVirusTotal(result: ScanResult, timeout: int) -> None:
  api_key = os.environ.get("VT_API_KEY")
  if not api_key:
    return

  target_url = result.dynamic_final_url or result.final_url or result.normalized_url

  try:
    data = functionVtGetUrlReport(target_url, api_key, timeout)
    result.virustotal = data

    stats = (
      data.get("data", {})
      .get("attributes", {})
      .get("last_analysis_stats", {})
    )

    malicious = int(stats.get("malicious", 0))
    suspicious = int(stats.get("suspicious", 0))
    harmless = int(stats.get("harmless", 0))
    undetected = int(stats.get("undetected", 0))

    if malicious > 0:
      functionAddFinding(
        result, "high", min(60, 20 + malicious * 4), "reputation",
        f"VirusTotal: malicious={malicious}, suspicious={suspicious}, "
        f"harmless={harmless}, undetected={undetected}"
      )
    elif suspicious > 0:
      functionAddFinding(
        result, "medium", min(20, 6 + suspicious * 2), "reputation",
        f"VirusTotal suspicious detections present: {suspicious}"
      )

  except Exception as exc:
    result.errors.append(f"VirusTotal check failed: {exc}")


async def functionScanUrl(args: argparse.Namespace) -> ScanResult:
  normalized = functionNormalizeUrl(args.url)
  result = ScanResult(
    requested_url=args.url,
    normalized_url=normalized
  )

  output_dir = Path(args.output_dir).expanduser().resolve()
  output_dir.mkdir(parents=True, exist_ok=True)

  functionAnalyzeUrlStructure(result, normalized)

  try:
    resp = functionFetchUrl(
      normalized,
      timeout=args.timeout,
      follow_redirects=not args.no_follow_redirects
    )
    functionAnalyzeResponse(
      result,
      resp,
      timeout=args.timeout,
      do_text_analysis=not args.no_text_analysis
    )
  except requests.RequestException as exc:
    result.errors.append(f"Static fetch failed: {exc}")

  if not args.no_dynamic:
    try:
      await functionRunDynamicStage(
        result=result,
        output_dir=output_dir,
        timeout=args.timeout,
        wait_ms=args.wait_ms,
        save_screenshot=not args.no_screenshot,
        save_html=not args.no_html,
        headed=args.headed
      )
    except Exception as exc:
      result.errors.append(f"Dynamic stage failed: {exc}")

  functionEnrichWithSafeBrowsing(result, args.timeout)
  functionEnrichWithVirusTotal(result, args.timeout)

  result.verdict = functionVerdictFromScore(result.score)
  return result


# =============================================================================
# Presentation
# =============================================================================

def functionResultToJsonable(result: ScanResult) -> Dict[str, Any]:
  data = asdict(result)
  data["findings"] = [asdict(f) for f in result.findings]
  return data


def functionPrintHuman(result: ScanResult, verbose: bool) -> None:
  print(f"Requested URL : {result.requested_url}")
  print(f"Normalized URL: {result.normalized_url}")
  print(f"Hostname      : {result.hostname}")
  print(f"Reg. domain   : {result.registered_domain}")
  print(f"IPs           : {', '.join(result.ip_addresses) or 'N/A'}")
  print(f"Fetched       : {result.fetched}")
  print(f"HTTP status   : {result.http_status}")
  print(f"Final URL     : {result.final_url}")
  print(f"Dynamic URL   : {result.dynamic_final_url}")
  print(f"Content-Type  : {result.content_type}")
  print(f"Title         : {result.title or result.dynamic_title}")
  print(f"Forms         : {result.forms_count}")
  print(f"Score         : {result.score}")
  print(f"Verdict       : {result.verdict}")

  if result.tls:
    print("TLS           :")
    print(f"  Subject CN  : {result.tls.subject_cn}")
    print(f"  Issuer      : {result.tls.issuer}")
    print(f"  Not after   : {result.tls.not_after}")
    print(f"  Days remain : {result.tls.days_remaining}")
    if result.tls.error:
      print(f"  Error       : {result.tls.error}")

  if result.redirect_chain:
    print("Static redirect chain:")
    for item in result.redirect_chain:
      print(f"  - {item}")

  if result.dynamic_redirects:
    print("Dynamic redirects:")
    for item in result.dynamic_redirects:
      print(f"  - {item['from']} -> {item['to']}")

  if result.suspicious_params:
    print("Suspicious query parameters:")
    for k, v in result.suspicious_params.items():
      print(f"  - {k} = {v}")

  if result.tracking_params:
    print("Tracking/query parameters:")
    for k, v in result.tracking_params.items():
      print(f"  - {k} = {v}")

  print("Findings:")
  if not result.findings:
    print("  - none")
  else:
    for finding in sorted(
      result.findings,
      key=lambda x: (-x.points, x.category, x.message)
    ):
      print(
        f"  - [{finding.severity.upper():6}] "
        f"+{finding.points:2d} {finding.category}: {finding.message}"
      )

  if verbose:
    if result.external_scripts:
      print("External scripts:")
      for src in result.external_scripts:
        print(f"  - {src}")

    if result.external_iframes:
      print("External iframes:")
      for src in result.external_iframes:
        print(f"  - {src}")

    if result.dynamic_requests:
      print("Dynamic requests:")
      for item in result.dynamic_requests[:100]:
        print(
          f"  - {item['method']:6} {item['resource_type']:10} "
          f"{item['url']}"
        )

    if result.dynamic_responses:
      print("Dynamic responses:")
      for item in result.dynamic_responses[:100]:
        print(
          f"  - {item['status']:3} {item['resource_type']:10} "
          f"{item['url']}"
        )

    if result.dynamic_console:
      print("Dynamic console:")
      for item in result.dynamic_console:
        print(f"  - {item['type']}: {item['text']}")

    if result.dynamic_page_errors:
      print("Dynamic page errors:")
      for item in result.dynamic_page_errors:
        print(f"  - {item}")

    if result.dynamic_downloads:
      print("Dynamic downloads:")
      for item in result.dynamic_downloads:
        print(f"  - {item}")

    if result.artifacts:
      print("Artifacts:")
      for k, v in result.artifacts.items():
        print(f"  - {k}: {v}")

    if result.errors:
      print("Errors:")
      for err in result.errors:
        print(f"  - {err}")


def functionParseArgs() -> argparse.Namespace:
  parser = argparse.ArgumentParser(
    description="Combined static + dynamic URL triage scanner."
  )
  parser.add_argument("url", help="URL to scan.")
  parser.add_argument(
    "--timeout",
    type=int,
    default=DEFAULT_TIMEOUT,
    help=f"Network timeout in seconds (default: {DEFAULT_TIMEOUT})."
  )
  parser.add_argument(
    "--wait-ms",
    type=int,
    default=DEFAULT_WAIT_MS,
    help=f"Dynamic post-load observation window in ms "
         f"(default: {DEFAULT_WAIT_MS})."
  )
  parser.add_argument(
    "--output-dir",
    default="./triage_output",
    help="Output directory for screenshots/HTML artifacts."
  )
  parser.add_argument(
    "--no-follow-redirects",
    action="store_true",
    help="Do not follow redirects in the static requests stage."
  )
  parser.add_argument(
    "--no-text-analysis",
    action="store_true",
    help="Disable visible page text heuristics in static stage."
  )
  parser.add_argument(
    "--no-dynamic",
    action="store_true",
    help="Disable Playwright dynamic stage."
  )
  parser.add_argument(
    "--no-screenshot",
    action="store_true",
    help="Do not save Playwright screenshot."
  )
  parser.add_argument(
    "--no-html",
    action="store_true",
    help="Do not save Playwright final DOM snapshot."
  )
  parser.add_argument(
    "--headed",
    action="store_true",
    help="Run Playwright headed instead of headless."
  )
  parser.add_argument(
    "--json",
    action="store_true",
    help="Print JSON to stdout instead of human-readable output."
  )
  parser.add_argument(
    "--json-out",
    help="Write JSON report to this file as well."
  )
  parser.add_argument(
    "--verbose",
    action="store_true",
    help="Show extended sections in human-readable output."
  )
  return parser.parse_args()


def functionMain() -> int:
  args = functionParseArgs()

  try:
    result = asyncio.run(functionScanUrl(args))
  except ValueError as exc:
    functionEprint(f"ERROR: {exc}")
    return 2

  data = functionResultToJsonable(result)

  if args.json:
    print(json.dumps(data, indent=2, ensure_ascii=False))
  else:
    functionPrintHuman(result, verbose=args.verbose)

  if args.json_out:
    with open(args.json_out, "w", encoding="utf-8") as handle:
      json.dump(data, handle, indent=2, ensure_ascii=False)

  return 0 if result.verdict != "high-risk" else 1


if __name__ == "__main__":
  raise SystemExit(functionMain())
