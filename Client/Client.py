# client.py - the simple client application.
# It runs on the Debian machine.
# Every X seconds it calls ONE function on the board (the Alive request) and prints the result.
#
#   python3 client.py      -> every 2 seconds
#   python3 client.py 5      -> every 5 seconds
# Stop it with Ctrl+C.

import sys
import time
import requests

SERVER_HOST = "192.168.0.2"  # the board (tap0 network)
SERVER_PORT = 5001
DEFAULT_INTERVAL = 2  # seconds between two calls
url = f"http://{SERVER_HOST}:{SERVER_PORT}/alive"


# Calls the Alive function on the board.
# Returns the answer as a dictionary, or None if the board did not answer.
def call_alive():
    try:
        response = requests.get(url, timeout=3)
        return response.json()
    except (
        requests.exceptions.RequestException
    ) as error:  # server down, network down, timeout...
        print("  no answer:", type(error).__name__)
        return None


# ---------------- main part ----------------

# read the interval from the command line (the first argument), or use the default
interval = DEFAULT_INTERVAL

if len(sys.argv) > 1:
    try:
        interval = float(sys.argv[1])
    except ValueError:
        print("the interval must be a number, for example: python3 client.py 5")
        sys.exit(1)

print(f"Calling {url} every {interval} seconds (Ctrl+C to stop)")

try:
    while True:
        now = time.strftime("%H:%M:%S")
        answer = call_alive()
        if answer is not None:
            print(f"{now}  Alive -> {answer}")
        time.sleep(interval)  # wait before the next call
except KeyboardInterrupt:
    print("\nClient stopped.")
