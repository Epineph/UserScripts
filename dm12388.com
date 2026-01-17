{
  "target": {
    "input": "https://dm12388.com/",
    "normalized_url": "https://dm12388.com/",
    "host": "dm12388.com"
  },
  "timestamps": {
    "started_utc": "2026-01-17T14:28:44+00:00",
    "finished_utc": "2026-01-17T14:30:16+00:00"
  },
  "modules": {
    "dns": true,
    "whois": true,
    "rdap": true,
    "http": true,
    "tls": true,
    "geo": true,
    "wappalyzer": true,
    "vuln": true,
    "playwright": false
  },
  "results": {
    "domain_parsing": {
      "input": "dm12388.com",
      "subdomain": null,
      "registered_domain": "dm12388.com",
      "suffix": "com"
    },
    "dns": {
      "A": [
        "69.72.83.246"
      ],
      "NS": [
        "a.share-dns.com.",
        "b.share-dns.net."
      ],
      "SOA": [
        "a.share-dns.com. master.share-dns.com. 1763472713 3600 1200 86400 600"
      ]
    },
    "whois": {
      "source": "whois(1)",
      "raw_text": "   Domain Name: DM12388.COM\n   Registry Domain ID: 3005649701_DOMAIN_COM-VRSN\n   Registrar WHOIS Server: whois.gname.com\n   Registrar URL: http://www.gname.com\n   Updated Date: 2025-11-18T12:56:49Z\n   Creation Date: 2025-07-30T23:58:07Z\n   Registry Expiry Date: 2026-07-30T23:58:07Z\n   Registrar: Gname.com Pte. Ltd.\n   Registrar IANA ID: 1923\n   Registrar Abuse Contact Email: complaint@gname.com\n   Registrar Abuse Contact Phone: +65.65189986\n   Domain Status: clientTransferProhibited https://icann.org/epp#clientTransferProhibited\n   Name Server: A2.SHARE-DNS.COM\n   Name Server: B2.SHARE-DNS.NET\n   DNSSEC: unsigned\n   URL of the ICANN Whois Inaccuracy Complaint Form: https://www.icann.org/wicf/\n>>> Last update of whois database: 2026-01-17T14:28:37Z <<<\n\nFor more information on Whois status codes, please visit https://icann.org/epp\n\nNOTICE: The expiration date displayed in this record is the date the\nregistrar's sponsorship of the domain name registration in the registry is\ncurrently set to expire. This date does not necessarily reflect the expiration\ndate of the domain name registrant's agreement with the sponsoring\nregistrar.  Users may consult the sponsoring registrar's Whois database to\nview the registrar's reported date of expiration for this registration.\n\nTERMS OF USE: You are not authorized to access or query our Whois\ndatabase through the use of electronic processes that are high-volume and\nautomated except as reasonably necessary to register domain names or\nmodify existing registrations; the Data in VeriSign Global Registry\nServices' (\"VeriSign\") Whois database is provided by VeriSign for\ninformation purposes only, and to assist persons in obtaining information\nabout or related to a domain name registration record. VeriSign does not\nguarantee its accuracy. By submitting a Whois query, you agree to abide\nby the following terms of use: You agree that you may use this Data only\nfor lawful purposes and that under no circumstances will you use this Data\nto: (1) allow, enable, or otherwise support the transmission of mass\nunsolicited, commercial advertising or solicitations via e-mail, telephone,\nor facsimile; or (2) enable high volume, automated, electronic processes\nthat apply to VeriSign (or its computer systems). The compilation,\nrepackaging, dissemination or other use of this Data is expressly\nprohibited without the prior written consent of VeriSign. You agree not to\nuse electronic processes that are automated and high-volume to access or\nquery the Whois database except as reasonably necessary to register\ndomain names or modify existing registrations. VeriSign reserves the right\nto restrict your access to the Whois database in its sole discretion to ensure\noperational stability.  VeriSign may restrict or terminate your access to the\nWhois database for failure to abide by these terms of use. VeriSign\nreserves the right to modify these terms at any time.\n\nThe Registry database contains ONLY .COM, .NET, .EDU domains and\nRegistrars.\nDomain Name: DM12388.COM\nRegistry Domain ID: 3005649701_DOMAIN_COM-VRSN\nRegistrar WHOIS Server: whois.gname.com\nRegistrar URL: www.gname.com\nUpdated Date: 2026-01-13T12:56:59Z\nCreation Date: 2025-07-30T23:58:07Z\nRegistrar Registration Expiration Date: 2026-07-30T23:58:07Z\nRegistrar: Gname.com Pte. Ltd.\nRegistrar IANA ID: 1923\nReseller:\nRegistrar Abuse Contact Email: complaint@gname.com\nRegistrar Abuse Contact Phone: +65.31581931\nDomain Status: clientTransferProhibited https://icann.org/epp#clientTransferProhibited\nRegistry Registrant ID: Redacted for privacy\nRegistrant Name: Redacted for privacy\nRegistrant Organization: Redacted for privacy\nRegistrant Street: Redacted for privacy\nRegistrant City: Redacted for privacy\nRegistrant State/Province: Redacted for privacy\nRegistrant Postal Code: Redacted for privacy\nRegistrant Country: CN\nRegistrant Phone: Redacted for privacy\nRegistrant Fax: Redacted for privacy\nRegistrant Email: https://rdap.gname.com/extra/contact?type=registrant&domain=DM12388.COM\nAdmin Name: Redacted for privacy\nAdmin Organization: Redacted for privacy\nAdmin Street: Redacted for privacy\nAdmin City: Redacted for privacy\nAdmin State/Province: Redacted for privacy\nAdmin Postal Code: Redacted for privacy\nAdmin Country: Redacted for privacy\nAdmin Phone: Redacted for privacy\nAdmin Fax: Redacted for privacy\nAdmin Email: https://rdap.gname.com/extra/contact?type=admin&domain=DM12388.COM\nTech Name: Redacted for privacy\nTech Organization: Redacted for privacy\nTech Street: Redacted for privacy\nTech City: Redacted for privacy\nTech State/Province: Redacted for privacy\nTech Postal Code: Redacted for privacy\nTech Country: Redacted for privacy\nTech Phone: Redacted for privacy\nTech Fax: Redacted for privacy\nTech Email: https://rdap.gname.com/extra/contact?type=technical&domain=DM12388.COM\nName Server: B2.SHARE-DNS.NET\nName Server: A2.SHARE-DNS.COM\nDNSSEC: unsigned\nURL of the ICANN Whois Inaccuracy Complaint Form: https://www.icann.org/wicf/\n>>> Last update of whois database: 2026-01-13T12:56:59Z <<<\n\nFor more information on Whois status codes, please visit https://icann.org/epp\n",
      "fields": {
        "Domain Name": "DM12388.COM",
        "Registry Domain ID": "3005649701_DOMAIN_COM-VRSN",
        "Registrar": "Gname.com Pte. Ltd.",
        "Registrar IANA ID": "1923",
        "Registrar URL": "www.gname.com",
        "Updated Date": "2026-01-13T12:56:59Z",
        "Creation Date": "2025-07-30T23:58:07Z",
        "Registrar Abuse Contact Email": "complaint@gname.com",
        "Registrar Abuse Contact Phone": "+65.31581931",
        "Domain Status": "clientTransferProhibited https://icann.org/epp#clientTransferProhibited",
        "Name Server": [
          "B2.SHARE-DNS.NET",
          "A2.SHARE-DNS.COM"
        ],
        "DNSSEC": "unsigned",
        "Registrant Organization": "Redacted for privacy",
        "Registrant Country": "CN",
        "Admin Email": "https://rdap.gname.com/extra/contact?type=admin&domain=DM12388.COM",
        "Tech Email": "https://rdap.gname.com/extra/contact?type=technical&domain=DM12388.COM"
      }
    },
    "rdap_domain": null,
    "resolved_ips": [
      "69.72.83.246"
    ],
    "rdap_ip": null,
    "ip_geolocation": {
      "status": "success",
      "country": "Hong Kong",
      "countryCode": "HK",
      "region": "KSS",
      "regionName": "Sham Shui Po District",
      "city": "Cheung Sha Wan",
      "zip": "",
      "lat": 22.3366,
      "lon": 114.151,
      "isp": "Netsec Limited",
      "org": "Netsec",
      "as": "AS45753 Netsec Limited",
      "asname": "NETSEC-HK",
      "reverse": "",
      "proxy": false,
      "hosting": true,
      "query": "69.72.83.246"
    },
    "http": {
      "request_url": "https://dm12388.com/",
      "final_url": "https://dm12388.com/",
      "status_code": 200,
      "headers": {
        "Server": "nginx",
        "Date": "Sat, 17 Jan 2026 14:28:49 GMT",
        "Content-Type": "text/html; charset=utf-8",
        "Connection": "keep-alive",
        "Vary": "Accept-Encoding",
        "Set-Cookie": "PHPSESSID=hm0gn80rai03g6lieo8dvvpno4; path=/; HttpOnly, pe_language=en; expires=Sun, 17-Jan-2027 14:28:49 GMT; Max-Age=31536000; path=/",
        "Expires": "Thu, 19 Nov 1981 08:52:00 GMT",
        "Cache-Control": "no-store, no-cache, must-revalidate",
        "Pragma": "no-cache",
        "Strict-Transport-Security": "max-age=31536000",
        "Alt-Svc": "quic=\":443\"; h3=\":443\"; h3-29=\":443\"; h3-27=\":443\";h3-25=\":443\"; h3-T050=\":443\"; h3-Q050=\":443\";h3-Q049=\":443\";h3-Q048=\":443\"; h3-Q046=\":443\"; h3-Q043=\":443\"",
        "Content-Encoding": "gzip"
      },
      "set_cookie_list": [
        "PHPSESSID=hm0gn80rai03g6lieo8dvvpno4; path=/; HttpOnly",
        "pe_language=en; expires=Sun, 17-Jan-2027 14:28:49 GMT; Max-Age=31536000; path=/"
      ]
    },
    "tls": {
      "host": "dm12388.com",
      "port": 443,
      "cert": {
        "subject": {
          "commonName": "dm12388.com"
        },
        "issuer": {
          "countryName": "US",
          "organizationName": "Let's Encrypt",
          "commonName": "R13"
        },
        "subjectAltName": [
          [
            "DNS",
            "a.dm12388.com"
          ],
          [
            "DNS",
            "dm12388.com"
          ]
        ],
        "notBefore": "Nov 18 12:34:46 2025 GMT",
        "notAfter": "Feb 16 12:34:45 2026 GMT",
        "version": 3,
        "serialNumber": "0610D95FEE9365E35F5EBA3CF9A1AB32D166"
      },
      "protocol": "TLSv1.3",
      "cipher": [
        "TLS_AES_256_GCM_SHA384",
        "TLSv1.3",
        256
      ],
      "days_until_expiry": 29,
      "ocsp_stapled": null
    },
    "wappalyzer": null,
    "page_snippet": {
      "url": "https://dm12388.com/",
      "status_code": 200,
      "content_type": "text/html; charset=utf-8",
      "length": 26742
    },
    "vulnerability_audit": {
      "security_headers": {
        "missing": [
          "content-security-policy",
          "x-frame-options",
          "x-content-type-options",
          "referrer-policy",
          "permissions-policy",
          "cross-origin-opener-policy",
          "cross-origin-resource-policy"
        ],
        "notes": {
          "hsts": "max-age=31536000",
          "hsts_note": "Consider includeSubDomains; preload requires it.",
          "hsts_preload_hint": "Eligible for preload only with 'preload' and long max-age.",
          "referrer_policy_note": "Missing Referrer-Policy (consider 'strict-origin-when-cross-origin' or stricter).",
          "permissions_policy_note": "Missing Permissions-Policy."
        },
        "cookies": [
          {
            "raw": "PHPSESSID=hm0gn80rai03g6lieo8dvvpno4; path=/; HttpOnly",
            "flags": {
              "secure": false,
              "httponly": true,
              "samesite": null
            }
          },
          {
            "raw": "pe_language=en; expires=Sun, 17-Jan-2027 14:28:49 GMT; Max-Age=31536000; path=/",
            "flags": {
              "secure": false,
              "httponly": false,
              "samesite": null
            }
          }
        ]
      },
      "http_methods": {
        "status": 405,
        "allow": null,
        "trace_status": 405
      },
      "mixed_content": [],
      "sensitive_files": [],
      "email_posture": {
        "spf": null,
        "dmarc": null,
        "issues": [
          "SPF record missing.",
          "DMARC record missing (_dmarc)."
        ]
      },
      "wordpress": {
        "detected": false,
        "core_version_hint": null,
        "generator": null,
        "plugins": {},
        "themes": {},
        "endpoints": {
          "/wp-json/": {
            "url": "https://dm12388.com/wp-json/",
            "status": 404,
            "length": 146,
            "note": null,
            "error": null
          },
          "/readme.html": {
            "url": "https://dm12388.com/readme.html",
            "status": 404,
            "length": 146,
            "note": null,
            "error": null
          },
          "/wp-login.php": {
            "url": "https://dm12388.com/wp-login.php",
            "status": 404,
            "length": 146,
            "note": null,
            "error": null
          },
          "/wp-admin/admin-ajax.php": {
            "url": "https://dm12388.com/wp-admin/admin-ajax.php",
            "status": 404,
            "length": 146,
            "note": null,
            "error": null
          },
          "/xmlrpc.php": {
            "url": "https://dm12388.com/xmlrpc.php",
            "status": 404,
            "length": 146,
            "note": null,
            "error": null
          },
          "/wp-content/uploads/": {
            "url": "https://dm12388.com/wp-content/uploads/",
            "status": 404,
            "length": 146,
            "note": null,
            "error": null
          }
        },
        "issues": []
      },
      "wpscan": null,
      "notes": []
    }
  },
  "errors": {
    "wappalyzer": "Wappalyzer CLI not found or failed; install with: npm i -g wappalyzer"
  }
}
