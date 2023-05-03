#!/usr/bin/python3
# Author:         Michael Lee
# Created date:   24APR2023
# Title:          fill_in_host_info_to_oracle_db_checklist.py
#                 Oracle Database STIG Checklist quick update for the HOST_NAME and HOST_IP fields under the ASSET branch (header of the XML file)
#
# Notes:          this tool can be used for a quick update to the Oracle Database STIG checklist ckl file.
#                 this is used to populate the HOST_NAME and HOST_IP fields in the XML formatted Oracle Database STIG checklist
#
#                 This tool is based on the contents of the "Oracle Database 12c Security Technical Implementation Guide", "Release: 6 Benchmark Date: 26 Jan 2023" XML formatted checklist file (*.ckl)
#                 This tool will also work on versions of this checklist going all the way back to V2R1 (Version 2, Release 1)
#
#                 Use python 3.4 or above due to use of method="c14n" with lxml
#
# Instructions:   Load the XML formatted ckl file for the Oracle Database 12c checklist on to your OS and then use this tool to fill in the HOST_NAME and HOST_IP fields.
#                 This script needs to be run on the same Oracle Database server where you are doing the STIG checks, so that the correct values are loaded to the XML file.
#
# Revisions:      3MAY2023 - gave it a detectable non-zero exit code if looking for errors via exit code in a shell script
# Runtime:        Should be less than 3 seconds in almost every case.
#

import argparse
import socket
import sys
from lxml import etree

MIN_PYTHON_VERSION = (3, 4)  #set your minimum Python version here
if sys.version_info < MIN_PYTHON_VERSION:
    print(f"Error: Python {MIN_PYTHON_VERSION[0]}.{MIN_PYTHON_VERSION[1]} or higher is required to run this script.")
    sys.exit(1)
	
error_detected = False

# Define the command line argument for the input XML file
parser = argparse.ArgumentParser()
parser.usage = '''This program loads the host name and host ip data into the XML formatted STIG checklist

 Usage: fill_in_host_info_to_oracle_db_checklist.py -f <ckl file>'''
parser.add_argument("-f", "--file", required=True, help="Path to input XML file")
args = parser.parse_args()

# Check that the input file is in XML format
try:
    etree.parse(args.file)
except etree.XMLSyntaxError:
    print(f"Error: {args.file} is not in valid XML format")
    exit()

# Get the hostname and IP address of the local machine
hostname = socket.gethostname()
ip_address = socket.gethostbyname(hostname)

# Open the input XML file
with open(args.file, "rb") as f:
    file_to_open = f.name
    # Parse the input XML file
    tree = etree.parse(f)

# Find the HOST_NAME and HOST_IP elements
host_name_elem = tree.find(".//HOST_NAME")
host_ip_elem = tree.find(".//HOST_IP")

# Update the HOST_NAME and HOST_IP elements with the local machine's hostname and IP address
host_name_elem.text = hostname
host_ip_elem.text = ip_address

# Write the resulting XML to a file using the c14n method
with open(file_to_open, "wb") as f:
    tree.write(f, method="c14n")

# Read the modified XML file back in and check that the HOST_NAME and HOST_IP fields were correctly populated
with open(file_to_open, "rb") as f:
    modified_tree = etree.parse(f)

modified_host_name_elem = modified_tree.find(".//HOST_NAME")
modified_host_ip_elem = modified_tree.find(".//HOST_IP")

if modified_host_name_elem.text == hostname:
    print(f"HOST_NAME field in {file_to_open} was correctly populated")
else:
    print(f"ERROR: HOST_NAME field in {file_to_open} was not correctly populated")
    error_detected=True

if modified_host_ip_elem.text == ip_address:
    print(f"HOST_IP field in {file_to_open} was correctly populated")
else:
    print(f"ERROR: HOST_IP field in {file_to_open} was not correctly populated")
    error_detected=True

if error_detected:
    sys.exit(1)
else:
    sys.exit(0)
