# rest_server.py - the minimal REST API server (Flask).
# It runs INSIDE the QEMU board.
# For now it has one address: /alive

import sys

sys.path.append("/work/pylibs")  # on the board, Flask is installed in this folder

from flask import Flask

HOST = "0.0.0.0"  # listen on every network interface of the board
PORT = 5001

app = Flask("monitor")


# Answers "I am alive". Flask turns the dictionary into JSON by itself.
# Only GET is allowed: any other method gets "405 Method Not Allowed" automatically.
@app.route("/alive")
def alive():
    return {"status": "alive"}


try:
    app.run(HOST, PORT)
except OSError as error:  # for example: port already in use
    print("error:", error)
