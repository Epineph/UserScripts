#!/usr/bin/env python3
"""
send_email.py

This script sends an email with the content of a Markdown (.md) file as the body.
Optionally, you can include an HTML version by converting the Markdown content.
Usage:
    python3 send_email.py recipient@example.com "Subject" /path/to/file.md

Requirements:
    - Python 3.x
    - (Optional) The 'markdown' package to convert Markdown to HTML:
          pip install markdown
"""

import sys
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart

def send_email(smtp_server, port, username, password, recipient, subject, markdown_file):
    # Read the Markdown file content
    try:
        with open(markdown_file, 'r') as f:
            content = f.read()
    except Exception as e:
        print(f"Error reading file: {e}")
        sys.exit(1)

    # Create a multipart email message
    msg = MIMEMultipart("alternative")
    msg['Subject'] = subject
    msg['From'] = username
    msg['To'] = recipient

    # Attach the plain text part (Markdown content)
    part1 = MIMEText(content, "plain")
    msg.attach(part1)

    # Optional: Convert Markdown to HTML and attach as HTML version
    # Uncomment the following block if you have installed the markdown package.
    """
    try:
        import markdown
        html_content = markdown.markdown(content)
        part2 = MIMEText(html_content, "html")
        msg.attach(part2)
    except ImportError:
        print("markdown package not installed; sending plain text email.")
    """

    # Connect to the SMTP server and send the email
    try:
        with smtplib.SMTP(smtp_server, port) as server:
            server.starttls()  # Secure the connection
            server.login(username, password)
            server.sendmail(username, recipient, msg.as_string())
        print("Email sent successfully.")
    except Exception as e:
        print(f"Error sending email: {e}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python3 send_email.py recipient@example.com 'Subject' /path/to/file.md")
        sys.exit(1)
    
    # SMTP server configuration - adjust these for your email provider
    SMTP_SERVER = "smtp.example.com"    # e.g., smtp.gmail.com for Gmail
    PORT = 587                          # TLS port (or 465 for SSL, with appropriate changes)
    USERNAME = "your_email@example.com" # Your email address
    PASSWORD = "your_email_password"    # Your email password or app-specific password

    recipient = sys.argv[1]
    subject = sys.argv[2]
    markdown_file = sys.argv[3]

    send_email(SMTP_SERVER, PORT, USERNAME, PASSWORD, recipient, subject, markdown_file)

