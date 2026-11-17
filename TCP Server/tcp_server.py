# tcp_server.py - the minimal TCP server.
# It runs INSIDE the QEMU board.
# It waits for a client, and sends back every text it gets in UPPERCASE.

import socket

HOST = "0.0.0.0"  # 0.0.0.0 = listen on every network interface of the board
PORT = 5000

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server_socket:
    # allow using the port again right away after the server was stopped
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        server_socket.bind((HOST, PORT))
        server_socket.listen()
        print(f"TCP server listening on {HOST}:{PORT}", flush=True)

        while True:
            client_socket, client_address = (
                server_socket.accept()
            )  # wait for the next client
            print("connected:", client_address, flush=True)

            with client_socket:
                try:
                    while True:
                        data = client_socket.recv(1024)  # b"" means the client closed
                        if not data:
                            break
                        received_text = data.decode("utf-8", "replace")
                        print("Received:", received_text, flush=True)
                        answer_text = received_text.upper()
                        client_socket.sendall(answer_text.encode("utf-8"))
                except ConnectionError as error:  # the client disappeared
                    print("client problem:", error, flush=True)
            print("closed:", client_address, flush=True)
    except OSError as error:  # for example: port already in use
        print("error:", error)
    except KeyboardInterrupt:
        print("\nserver stopped")
