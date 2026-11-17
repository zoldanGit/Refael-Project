# serial_client.py - the minimal serial client.
# It runs on the Debian machine.
# It sends the text you type to the board and prints the answer.

import serial

SERIAL_DEVICE = "/tmp/virtual-uart"   # made by ./setupuart
BAUD_RATE = 115200

try:
    with serial.Serial(SERIAL_DEVICE, BAUD_RATE, timeout=5) as serial_port:
        print("Connected to the board!")

        while True:
            command_text = input("Enter text (or exit): ").strip()

            if command_text.lower() == "exit":
                break
            if not command_text:
                continue

            serial_port.write((command_text + "\n").encode("utf-8"))
            serial_port.flush()

            line = serial_port.readline()  # wait up to 5 seconds for the answer
            if line:
                print("Board:", line.decode("utf-8", "replace").strip())
            else:
                print("No response from the board")

except serial.SerialException as error:
    print("serial error:", error)
except (KeyboardInterrupt, EOFError):
    print("\nClient interrupted.")

print("Disconnected. Goodbye!")
