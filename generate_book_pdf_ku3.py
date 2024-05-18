import requests
from bs4 import BeautifulSoup
import os
import re

# Function to log in via the university portal
def login_via_university(session, username, password):
    # Initial URL to start the login process
    login_start_url = "https://soeg.kb.dk/view/action/uresolver.do?operation=resolveService&package_service_id=90043166160005763&institutionId=5763&customerId=5760&VE=true"
    initial_response = session.get(login_start_url, verify=False)
    
    # Assuming the login form is in the response, parse it
    soup = BeautifulSoup(initial_response.text, 'html.parser')
    login_form = soup.find('form')
    
    if login_form is None:
        print("Failed to find the login form.")
        return None

    # Extract form action and hidden inputs
    login_url = login_form['action']
    payload = {tag['name']: tag.get('value', '') for tag in login_form.find_all('input') if tag.get('name')}
    payload['username'] = username
    payload['password'] = password
    
    # Submit the login form
    response = session.post(login_url, data=payload, verify=False)
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
        # Step 1: Log in via the university portal
        login_response = login_via_university(session, username, password)
        if login_response and login_response.status_code == 200:
            print("Logged in successfully.")
            
            # Step 2: Fetch chapter links
            chapter_links = fetch_chapter_links(session, base_url)
            
            # Step 3: Download PDFs
            download_pdfs(session, chapter_links, save_dir)
        else:
            print("Failed to log in.")

if __name__ == "__main__":
    main()

