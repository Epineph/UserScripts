#!/bin/bash

# Function to prompt for missing arguments
prompt_for_input() {
    if [ -z "$SSID" ]; then
        read -p "Enter the SSID (Network Name): " SSID
    fi
    if [ -z "$PASSWORD" ]; then
        read -s -p "Enter the Wi-Fi Password: " PASSWORD
        echo
    fi
    if [ -z "$INTERFACE" ]; then
        read -p "Enter the Network Interface (e.g., wlan0): " INTERFACE
    fi
    if [ -z "$INTERVAL" ]; then
        read -p "Enter the Reconnection Interval (in seconds): " INTERVAL
    fi
}

# Parsing command-line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -I|--id) SSID="$2"; shift ;;
        -P|--password) PASSWORD="$2"; shift ;;
        -N|--name) INTERFACE="$2"; shift ;;
        -T|--timer) INTERVAL="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Prompt for any missing arguments
prompt_for_input

# Function to check connection status
check_connection() {
   

