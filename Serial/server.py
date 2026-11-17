# serial_server.py - the minimal serial application.
# It runs INSIDE the QEMU board.
# It reads one line from the serial port and sends it back in UPPERCASE.

import serial

SERIAL_DEVICE = "/dev/ttyAMA0"  # the serial port inside the board
BAUD_RATE = 115200

try:
    with serial.Serial(SERIAL_DEVICE, BAUD_RATE, timeout=1) as serial_port:
        print(f"Serial server ready on {SERIAL_DEVICE}", flush=True)

        while True:
            line = serial_port.readline()  # wait up to 1 second for a full line
            if not line:  # nothing arrived, try again
                continue

            received_text = line.decode("utf-8", "replace").strip()
            print("Received:", received_text, flush=True)

            answer_text = received_text.upper()
            serial_port.write((answer_text + "\n").encode("utf-8"))

except serial.SerialException as error:  # device missing, no permission, ...
    print("serial error:", error)
except KeyboardInterrupt:
    print("\nserver stopped")
