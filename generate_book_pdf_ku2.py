import requests
from bs4 import BeautifulSoup
import os
import re

# Function to log in via the university portal
def login_via_university(session, username, password):
    login_page = "https://login.kb.dk"  # Replace with the actual login URL for your university
    auth_payload = {
        'username': username,
        'password': password,
    }
    response = session.post(login_page, data=auth_payload, verify=False)  # Disable SSL verification for simplicity
    return response

# Function to fetch chapter links
def fetch_chapter_links(session, base_url):
    response = session.get(base_url, verify=False)  # Disable SSL verification for simplicity
    soup = BeautifulSoup(response.text, 'html.parser')
    
    # Find all chapter links
    chapter_links = []
    for link in soup.find_all('a', href=True):
        if re.search(r'\.pdf$', link['href']):
            chapter_links.append(link['href'])
    
    return chapter_links

# Function to download PDFs
def download_pdfs(session, chapter_links, save_dir):
    if not os.path.exists(save_dir):
        os.makedirs(save_dir)
    
    for i, link in enumerate(chapter_links, start=1):
        pdf_url = link
        pdf_response = session.get(pdf_url, verify=False)  # Disable SSL verification for simplicity
        
        pdf_path = os.path.join(save_dir, f'{i}.pdf')
        with open(pdf_path, 'wb') as f:
            f.write(pdf_response.content)
        
        print(f'Downloaded: {pdf_path}')

# Main function
def main():
    username = input("Enter your university email: ")
    password = input("Enter your university password: ")
    
    base_url = "https://www-jstor-org.ep.fjernadgang.kb.dk/stable/j.ctv18phgrr"
    save_dir = "downloaded_pdfs"
    
    with requests.Session() as session:
        # Step 1: Access JSTOR via the university's library proxy
        initial_response = session.get(base_url, verify=False)  # Disable SSL verification for simplicity
        
        # Step 2: Log in via the university portal
        login_response = login_via_university(session, username, password)
        if login_response.status_code == 200:
            print("Logged in successfully.")
            
            # Step 3: Fetch chapter links
            chapter_links = fetch_chapter_links(session, base_url)
            
            # Step 4: Download PDFs
            download_pdfs(session, chapter_links, save_dir)
        else:
            print("Failed to log in.")

if __name__ == "__main__":
    main()

