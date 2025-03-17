#!/usr/bin/env python3

import socket

# Creating a socket object

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# Sending a dummy packet to a public DNS server

s.connect(("8.8.8.8", 80))

# getting local IP address

ip = s.getsockname()[0]

# printing the IP address

print("Your IP address is:", ip)

# close the socket connection

s.close()
