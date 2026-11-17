# tcp_client.py - the minimal TCP client.
# It runs on the Debian machine.
# It sends the text you type to the board and prints the answer.

import socket

SERVER_HOST = "192.168.0.2"  # the board (tap0 network)
SERVER_PORT = 5000

try:
    with socket.create_connection(
        (SERVER_HOST, SERVER_PORT), timeout=5
    ) as client_socket:
        print(f"Connected to {SERVER_HOST}:{SERVER_PORT}")
        while True:
            command_text = input("Enter text (or exit): ").strip()
            if command_text.lower() == "exit":
                break
            if not command_text:
                continue
            client_socket.sendall(command_text.encode("utf-8"))
            data = client_socket.recv(1024)  # wait up to 5 seconds for the answer
            if not data:
                print("The server closed the connection")
                break
            print("Board:", data.decode("utf-8", "replace"))
except ConnectionRefusedError:
    print("cannot connect: is the server running on the board?")
except socket.timeout:
    print("no answer from the server (timeout)")
except OSError as error:  # wrong IP, network down, ...
    print("error:", error)
except (KeyboardInterrupt, EOFError):
    print("\nClient interrupted.")

print("Disconnected. Goodbye!")
