from flask import Flask, render_template, request, jsonify, redirect, url_for
from selenium import webdriver
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.chrome.options import Options
from webdriver_manager.chrome import ChromeDriverManager
from bs4 import BeautifulSoup
from PIL import Image
import os
import time
from urllib.parse import urljoin

app = Flask(__name__)

# Настройка пути для хранения скриншотов
SCREENSHOTS_FOLDER = 'static/screenshots'
if not os.path.exists(SCREENSHOTS_FOLDER):
    os.makedirs(SCREENSHOTS_FOLDER)

def is_valid_url(url):
    import re
    url_pattern = re.compile(r'^(https?:\/\/)?'+
                             r'(([a-zA-Z\d]([a-zA-Z\d-]*[a-zA-Z\d])*)\.)+[a-zA-Z]{2,}'+
                             r'(:\d+)?(\/[-a-zA-Z\d%_.~+]*)*'+
                             r'(\?[;&a-zA-Z\d%_.~+=-]*)?'+
                             r'(#[-a-zA-Z\d_]*)?$')
    return re.match(url_pattern, url) is not None

def init_browser():
    options = Options()
    options.add_argument('--headless')
    options.add_argument('--disable-gpu')
    options.add_argument('--window-size=1800x1200')

    service = Service(ChromeDriverManager().install())
    driver = webdriver.Chrome(service=service, options=options)
    return driver

def capture_screenshot(driver, url, filename):
    driver.get(url)
    time.sleep(2)  # Дождитесь полной загрузки страницы

    screenshot_path = os.path.join(SCREENSHOTS_FOLDER, filename)
    driver.save_screenshot(screenshot_path)

    with Image.open(screenshot_path) as img:
        img = img.resize((450, 300), Image.Resampling.LANCZOS)
        img.save(screenshot_path)

    return screenshot_path

def capture_screenshot_and_parse_links(driver, base_url, filename):
    driver.get(base_url)
    time.sleep(2)  # Дождитесь полной загрузки страницы

    screenshot_path = os.path.join(SCREENSHOTS_FOLDER, filename)
    driver.save_screenshot(screenshot_path)

    with Image.open(screenshot_path) as img:
        img = img.resize((600, 400 ), Image.Resampling.LANCZOS)
        img.save(screenshot_path)

    soup = BeautifulSoup(driver.page_source, 'html.parser')
    links = [urljoin(base_url, a.get('href')) for a in soup.find_all('a', href=True)]

    return screenshot_path, links

@app.route('/')
def home():
    return render_template('index.html')

@app.route('/submit', methods=['GET', 'POST'])
def submit():
    if request.method == 'POST':
        user_input = request.form['user_input']
    else:
        user_input = request.args.get('user_input')

    if is_valid_url(user_input):
        if not user_input.startswith(('http://', 'https://')):
            user_input = 'http://' + user_input

        driver = init_browser()
        filename = 'screenshot.png'
        screenshot_path, links = capture_screenshot_and_parse_links(driver, user_input, filename)

        max_links = 10
        links = links[:max_links]

        driver.quit()

        return render_template('links.html', url=user_input, screenshot_url=screenshot_path, links=links)
    else:
        return jsonify({"is_url": False, "message": f"Received: {user_input}"})

@app.route('/capture_screenshot', methods=['POST'])
def capture_screenshot_route():
    link = request.json['link']
    filename = f'link_screenshot_{hash(link)}.png'

    driver = init_browser()
    capture_screenshot(driver, link, filename)
    driver.quit()

    return jsonify({'url': link, 'screenshot': os.path.join(SCREENSHOTS_FOLDER, filename)})

@app.route('/parse_again', methods=['POST'])
def parse_again():
    link = request.json['link']

    if is_valid_url(link):
        if not link.startswith(('http://', 'https://')):
            link = 'http://' + link

        driver = init_browser()
        filename = 'screenshot.png'
        screenshot_path, links = capture_screenshot_and_parse_links(driver, link, filename)

        max_links = 10
        links = links[:max_links]

        driver.quit()

        return jsonify({'url': link, 'screenshot_url': screenshot_path, 'links': links})
    else:
        return jsonify({"is_url": False, "message": f"Received: {link}"})

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=True)
