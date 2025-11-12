#!/usr/bin/env python3

import sys
import re
import requests
from bs4 import BeautifulSoup
import whois
import datetime
import json

# Optional: if you want to do a VirusTotal domain reputation check.
# pip install python-dotenv
# Then create a .env file with VIRUSTOTAL_API_KEY=your_api_key
try:
    from dotenv import load_dotenv
    import os
    load_dotenv()
    VIRUSTOTAL_API_KEY = os.getenv('VIRUSTOTAL_API_KEY', None)
except ImportError:
    VIRUSTOTAL_API_KEY = None

# Keywords that might indicate phishing or card info requests
SUSPICIOUS_KEYWORDS = [
    "credit card",
    "card number",
    "cvv",
    "expiry date",
    "pin",
    "paypal",
    "bank login",
    "gift card",
]

def check_domain_info(domain):
    """
    Retrieves domain WHOIS info and checks:
      - domain creation date
      - domain registrar
      - domain expiration date, etc.
    """
    try:
        w = whois.whois(domain)
    except Exception as e:
        print(f"[!] WHOIS lookup failed: {e}")
        return

    # Print or store the results
    print("=== Domain WHOIS Info ===")
    # Some domain TLDs have different formats. 'creation_date' can be None or a list.
    creation_date = w.creation_date
    if isinstance(creation_date, list):
        creation_date = creation_date[0]
    registrar = w.registrar
    expiration_date = w.expiration_date
    if isinstance(expiration_date, list):
        expiration_date = expiration_date[0]

    print(f"Registrar:      {registrar}")
    print(f"Creation Date:  {creation_date}")
    print(f"Expiration Date:{expiration_date}")
    print(f"WHOIS Name:     {w.name}")
    print(f"WHOIS Org:      {w.org}")
    print(f"WHOIS Country:  {w.country}")
    print("")

    # Check age of domain
    if creation_date and isinstance(creation_date, datetime.datetime):
        domain_age_days = (datetime.datetime.now() - creation_date).days
        print(f"Domain age (days): {domain_age_days}")
        if domain_age_days < 180:
            print("[!] Red Flag: Domain is younger than 6 months.")
    else:
        print("[!] Could not determine creation date for domain.")

    print("")

def fetch_webpage(url):
    """
    Fetches the webpage HTML content using requests.
    """
    try:
        response = requests.get(url, timeout=10)
        if response.status_code == 200:
            return response.text
        else:
            print(f"[!] HTTP Error: {response.status_code}")
            return ""
    except requests.exceptions.RequestException as e:
        print(f"[!] Failed to fetch page: {e}")
        return ""

def analyze_html(html):
    """
    Analyzes the HTML content for suspicious keywords,
    suspicious form fields, external JS references, etc.
    """
    soup = BeautifulSoup(html, 'html.parser')

    print("=== Analyzing HTML Content for Suspicious Elements ===")

    # 1. Check for suspicious keywords in the entire text
    lower_html = html.lower()
    for kw in SUSPICIOUS_KEYWORDS:
        if kw in lower_html:
            print(f"[!] Found suspicious keyword in HTML: '{kw}'")

    # 2. Check all forms
    forms = soup.find_all('form')
    print(f"Found {len(forms)} form(s).")
    for i, form in enumerate(forms, 1):
        print(f"  Form #{i} method={form.get('method')} action={form.get('action')}")
        # Inspect input fields
        inputs = form.find_all('input')
        for inp in inputs:
            input_type = inp.get('type', '')
            input_name = inp.get('name', '')
            if 'card' in input_name.lower() or 'credit' in input_name.lower():
                print(f"    [!] Suspicious input field detected: name={input_name} type={input_type}")

    # 3. Check for external script sources
    scripts = soup.find_all('script')
    external_scripts = []
    for script in scripts:
        src = script.get('src')
        if src and not src.startswith('/'):  # If it's external or absolute
            external_scripts.append(src)

    if external_scripts:
        print("External script references found:")
        for scr in external_scripts:
            print(f"  - {scr}")
            # Potentially check if domain is suspicious, or if loaded over http instead of https
            if scr.startswith("http://"):
                print("    [!] Script loaded via HTTP (not HTTPS).")

    print("=== End of HTML Analysis ===\n")

def check_virus_total(domain):
    """
    (Optional) Checks the domain against VirusTotal's URL scan/reputation API.
    Requires a valid API key in the environment variable: VIRUSTOTAL_API_KEY
    """
    if not VIRUSTOTAL_API_KEY:
        print("[-] Skipping VirusTotal check because no API key was found.")
        return

    print("=== Checking domain with VirusTotal ===")
    url = f"https://www.virustotal.com/api/v3/domains/{domain}"
    headers = {
        "x-apikey": VIRUSTOTAL_API_KEY
    }
    try:
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code == 200:
            data = response.json()
            # Quick summary
            stats = data["data"]["attributes"]["last_analysis_stats"]
            print("VirusTotal Analysis Stats:")
            print(json.dumps(stats, indent=2))
            # E.g. {"harmless": 72, "malicious": 2, "suspicious": 0, "undetected": 11, "timeout": 0}
            if stats["malicious"] > 0 or stats["suspicious"] > 0:
                print("[!] This domain has been flagged by VirusTotal.")
        else:
            print(f"[!] VirusTotal API returned status code {response.status_code}")
    except Exception as e:
        print(f"[!] VirusTotal check failed: {e}")
    print("")

def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <url>")
        sys.exit(1)

    url = sys.argv[1].strip()
    # Basic sanity: extract domain from URL
    # e.g., 'https://checkallcards.jimdofree.com' -> 'checkallcards.jimdofree.com'
    domain = url.replace("http://", "").replace("https://", "").split('/')[0]

    print(f"[*] Analyzing {url}")

    # 1. Check domain WHOIS
    check_domain_info(domain)

    # 2. Fetch and analyze HTML
    html = fetch_webpage(url)
    if html:
        analyze_html(html)

    # 3. (Optional) Check domain against VirusTotal
    check_virus_total(domain)

    print("=== Finished Analysis ===")

if __name__ == "__main__":
    main()

