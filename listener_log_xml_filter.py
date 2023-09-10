#!/usr/bin/python3
# Author:       Michael Lee
# Title:        listener_log_xml_filter.py - Oracle Database Listener Log Filter
# Created date: 11SEP2023
# Instructions: Example: To filter on a host address,ip address, execute this:                ./listener_log_xml_filter.py -f <xml listener log to read> -a <host ip>
#                        To filter on a pid, execute this:                                    ./listener_log_xml_filter.py -f <xml listener log to read> -p <pid>
#                        To filter on both a host address/ip address and a pid, execute this: ./listener_log_xml_filter.py -f <xml listener log to read> -a <host ip> -p <pid>
#                        To list out all unique host addresses/ip addresses, execute this:    ./listener_log_xml_filter.py -f <xml listener log to read> --list-hosts
#                        To show all recent errors in the last (default is 24 hours):         ./listener_log_xml_filter.py -f <xml listener log to read> --recent-errors
#                        To show all recent errors with a time override for the default:      ./listener_log_xml_filter.py -f <xml listener log to read> --recent-errors --error-hours 5  # example for 5 hours
#
# Revisions:    11SEP2023 - first draft
#
# Notes:        use python 3.4 or above due to use of argparse.FileType
#               WARNING: This script will load the entire XML formatted listener log into memory in order to parse/filter the file.  This could be very memory intensive if the listener log file is large.
#                        This is due to the use of args.file.read()
#                        Recommendation: rotate your XML formatted listener log files at least weekly in order to avoid memory intensive executions of this script.
#
#               This script was tested on XML formatted listener logs in Oracle Database 21c.
#
# TODO:         Might add additional filters later like org_id, comp_id, type, host_id, and even time
#

import argparse
from datetime import datetime, timedelta
import os
import sys
try:
    from lxml import etree as ET
except ImportError:
    print("Error: The 'lxml' module is not available. Please install it using 'pip3 install lxml' or 'pip install lxml' and try again.")
    sys.exit(1)

MIN_PYTHON_VERSION = (3, 4)  #set your minimum Python version here
if sys.version_info < MIN_PYTHON_VERSION:
    print(f"Error: Python {MIN_PYTHON_VERSION[0]}.{MIN_PYTHON_VERSION[1]} or higher is required to run this script.")
    sys.exit(1)

def is_recent_error(log_time, hours=24):
    """Check if the log_time is within the last 'hours' hours."""
    if log_time is None:
        return False
    delta = datetime.now() - log_time
    return delta <= timedelta(hours=hours)

def process_msg(msg_content):
    tree = ET.fromstring(msg_content)
    host_addr = tree.get('host_addr')
    pid = tree.get('pid')
    time_str = tree.get('time')
    txt = tree.find('txt').text
    org_id = tree.get('org_id')       # Extract org_id
    comp_id = tree.get('comp_id')     # Extract comp_id
    msg_type = tree.get('type')       # Extract type
    level = tree.get('level')         # Extract level
    host_id = tree.get('host_id')     # Extract host_id
    
    # Parsing the date-time from the time attribute of msg element
    try:
        log_time = datetime.strptime(time_str.split('.')[0], '%Y-%m-%dT%H:%M:%S')
    except ValueError:
        # Handle unexpected date-time format
        log_time = None

    return log_time, host_addr, pid, txt, org_id, comp_id, msg_type, level, host_id

def print_msgs_from_xml(xml_content, host_addr_filter=None, pid_filter=None, recent_errors=False, error_hours=24):
    for fragment in xml_content.split("<msg"):
        if not fragment.strip():
            continue
        msg_content = "<msg" + fragment
        try:
            time, host_addr, pid, txt, org_id, comp_id, msg_type, level, host_id = process_msg(msg_content)
            
            if host_addr_filter and host_addr != host_addr_filter:
                continue
            if pid_filter and pid != pid_filter:
                continue

            if recent_errors:
                # Check for error strings first.
                if "TNS-" not in txt and "Error" not in txt:
                    continue
                
                # Now, instead of parsing the timestamp from 'txt', use the 'time' directly
                if not is_recent_error(time, error_hours):
                    continue
            
            cleaned_txt = txt.replace('\n', ' ')
            output = (f"time={time} org_id={org_id} comp_id={comp_id} type={msg_type} level={level} host_id={host_id} "
                      f"host_addr={host_addr} pid={pid} {cleaned_txt}")
            print(output)
        except ET.XMLSyntaxError:
            continue

def list_unique_host_addrs(xml_content):
    host_addrs = set()
    for fragment in xml_content.split("<msg"):
        if not fragment.strip():
            continue
        msg_content = "<msg" + fragment
        try:
            host_addr = process_msg(msg_content)[1]
            if host_addr:
                host_addrs.add(host_addr)
        except ET.XMLSyntaxError:
            continue

    for addr in sorted(host_addrs):
        print(addr)

def main():
    parser = argparse.ArgumentParser(description="Filter and print XML messages from the XML formatted listener log")
    parser.add_argument('-f', '--file', type=argparse.FileType('r'), required=True, help='Path to the XML formatted listener log')
    parser.add_argument('-a', '--host_addr', type=str, help='Filter by host address')
    parser.add_argument('-p', '--pid', type=str, help='Filter by pid')
    parser.add_argument('--list-hosts', '-lh', action='store_true', help='List all unique host addresses from the XML file')
    parser.add_argument('--recent-errors', '-re', action='store_true', help='Show only recent errors from the XML file')
    parser.add_argument('--error-hours', '-eh', type=int, default=24, help='Hours to look back for recent errors, default is 24 hours')
    args = parser.parse_args()
	
	# Check the file size
    file_size = os.path.getsize(args.file.name)
    if file_size > (1 << 30):  # 1 GB in bytes
        print("Warning: The file size is over 1 GB. Processing might take some time.")
        print("If you see this warning, you might want to start questioning your career choice as an Oracle DBA.")
        print("At least start rotating the listener log so that it doesn't grow so large.")
        # If you wish to exit the script due to file size being too large, uncomment the next line:
        # sys.exit(1)

    xml_content = args.file.read()

    if args.list_hosts:
        list_unique_host_addrs(xml_content)
    elif args.recent_errors:
        print_msgs_from_xml(xml_content, args.host_addr, args.pid, True, args.error_hours)
    else:
        print_msgs_from_xml(xml_content, args.host_addr, args.pid)

if __name__ == '__main__':
    main()
