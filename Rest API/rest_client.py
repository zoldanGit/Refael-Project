# rest_client.py - the minimal REST API client.
# It runs on the Debian machine.
# It asks the board "are you alive?" and prints the answer.

import requests

SERVER_HOST = "192.168.0.2"  # the board (tap0 network)
SERVER_PORT = 5001

url = f"http://{SERVER_HOST}:{SERVER_PORT}/alive"

try:
    response = requests.get(url, timeout=5)
    print("status code:", response.status_code)
    print("answer:", response.json())
except requests.exceptions.ConnectionError:
    print("cannot connect: is the server running on the board?")
except requests.exceptions.Timeout:
    print("no answer from the server (timeout)")
except requests.exceptions.RequestException as error:  # any other problem
    print("error:", error)
