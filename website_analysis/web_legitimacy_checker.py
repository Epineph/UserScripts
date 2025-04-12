#!/usr/bin/env python3
"""
web_legitimacy_checker.py

DESCRIPTION:
    This script attempts to assess basic legitimacy indicators of a given website.
    It performs:
    1. WHOIS lookup for domain creation date, registrar, expiry, etc.
    2. SSL certificate inspection (validity, issuer, expiry date).

    NOTE: This is by no means a guarantee of legitimacy or safety. It is simply
    a heuristic approach to flag obvious red flags (e.g., extremely recent domain
    registration, missing WHOIS data, expired SSL certificates).

USAGE:
    python web_legitimacy_checker.py <domain_name>

EXAMPLE:
    python web_legitimacy_checker.py example.com

AUTHOR:
    [Your Name or Organization]

VERSION:
    1.0

LICENSE:
    This script is provided "as is" without any warranties. Use at your own risk.
"""

import sys
import ssl
import socket
from datetime import datetime
try:
    import whois  # python-whois or whois package
except ImportError:
    print("Please install the 'python-whois' package (pip install python-whois).")
    sys.exit(1)

def get_domain_whois_info(domain: str) -> dict:
    """
    Perform a WHOIS lookup and return relevant domain information.

    PARAMETERS:
        domain (str): The domain name to query.

    RETURNS:
        whois_data (dict): Dictionary containing:
            - creation_date: The domain creation date (if available)
            - expiration_date: The domain expiration date (if available)
            - registrar: Registrar information
            - name_servers: List of name servers
    """
    try:
        w = whois.whois(domain)
        # The whois library can return single or multiple dates, so handle that
        creation_date = w.creation_date
        expiration_date = w.expiration_date
        registrar = w.registrar
        name_servers = w.name_servers

        # Ensure these fields are lists or single values depending on the domain/WHOIS server
        if isinstance(creation_date, list):
            creation_date = creation_date[0]
        if isinstance(expiration_date, list):
            expiration_date = expiration_date[0]

        whois_data = {
            'creation_date': creation_date,
            'expiration_date': expiration_date,
            'registrar': registrar,
            'name_servers': name_servers
        }
        return whois_data
    except Exception as e:
        print(f"WHOIS lookup failed for {domain}. Error: {e}")
        return {}

def get_ssl_certificate_info(domain: str, port: int = 443) -> dict:
    """
    Retrieve SSL certificate information from the given domain.

    PARAMETERS:
        domain (str): The domain name to connect to (typically port 443).
        port (int, optional): The port number for HTTPS (defaults to 443).

    RETURNS:
        cert_info (dict): Dictionary containing:
            - issuer: The issuer of the certificate
            - subject: The subject of the certificate
            - valid_from: The start of certificate validity (datetime)
            - valid_to: The end of certificate validity (datetime)
    """
    cert_info = {}
    context = ssl.create_default_context()

    try:
        with socket.create_connection((domain, port), timeout=5) as sock:
            with context.wrap_socket(sock, server_hostname=domain) as ssock:
                cert = ssock.getpeercert()
                # The 'subject' and 'issuer' fields in the cert are lists of tuples.
                subject = dict(x[0] for x in cert.get('subject', []))
                issuer = dict(x[0] for x in cert.get('issuer', []))

                # Extract validity times
                # Python's ssl library typically uses 'notBefore' / 'notAfter' keys
                start_str = cert.get('notBefore')
                end_str = cert.get('notAfter')

                # Convert strings to datetime objects
                valid_from = datetime.strptime(start_str, '%b %d %H:%M:%S %Y %Z')
                valid_to = datetime.strptime(end_str, '%b %d %H:%M:%S %Y %Z')

                cert_info = {
                    'subject': subject,     # e.g. {'commonName': 'example.com'}
                    'issuer': issuer,       # e.g. {'commonName': 'R3', 'organizationName': 'Let\'s Encrypt'}
                    'valid_from': valid_from,
                    'valid_to': valid_to,
                }
    except Exception as e:
        print(f"SSL certificate check failed for {domain}. Error: {e}")

    return cert_info

def analyze_domain(domain: str) -> None:
    """
    Consolidate domain checks: WHOIS + SSL certificate inspection.

    PARAMETERS:
        domain (str): Domain name to be analyzed.

    SIDE EFFECTS:
        Prints analysis results to the console.
    """
    print(f"Analyzing domain: {domain}\n")

    # WHOIS Lookup
    whois_data = get_domain_whois_info(domain)
    creation_date = whois_data.get('creation_date', None)
    expiration_date = whois_data.get('expiration_date', None)
    registrar = whois_data.get('registrar', None)
    name_servers = whois_data.get('name_servers', None)

    print("WHOIS Information:")
    print(f"  - Registrar:      {registrar}")
    print(f"  - Creation Date:  {creation_date}")
    print(f"  - Expiration Date:{expiration_date}")
    print(f"  - Name Servers:   {name_servers}\n")

    # Basic age check (flag if domain is very young)
    if creation_date:
        domain_age = datetime.now() - creation_date if isinstance(creation_date, datetime) else None
        if domain_age and domain_age.days < 30:
            print("WARNING: This domain is younger than 1 month. This could be suspicious.")

    # SSL Certificate Inspection
    cert_info = get_ssl_certificate_info(domain)
    if cert_info:
        subject = cert_info.get('subject', {})
        issuer = cert_info.get('issuer', {})
        valid_from = cert_info.get('valid_from')
        valid_to = cert_info.get('valid_to')

        print("SSL Certificate Information:")
        print(f"  - Subject:    {subject}")
        print(f"  - Issuer:     {issuer}")
        print(f"  - Valid From: {valid_from}")
        print(f"  - Valid To:   {valid_to}\n")

        # Check if certificate is currently valid
        now = datetime.utcnow()
        if valid_from and valid_to:
            if now < valid_from or now > valid_to:
                print("WARNING: SSL certificate is not currently valid (expired or not yet valid).")
    else:
        print("No SSL certificate information found. Possibly no HTTPS or handshake failed.\n")

    # Add any additional logic or checks here
    # e.g., checking Google Safe Browsing APIs, known blacklists, etc.

    print("Analysis complete.\n")

def main():
    """
    Main entry point. Grabs a domain name from command line arguments and runs analysis.
    """
    if len(sys.argv) < 2:
        print("Usage: python web_legitimacy_checker.py <domain>")
        sys.exit(1)

    domain = sys.argv[1]
    analyze_domain(domain)

if __name__ == "__main__":
    main()

