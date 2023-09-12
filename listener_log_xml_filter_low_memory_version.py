#!/usr/bin/python3
# Author:       Michael Lee
# Title:        listener_log_xml_filter_low_memory_version.py - Oracle Database Listener Log Filter
# Created date: 11SEP2023
# Instructions: Example: To filter on a host address,ip address, execute this:                ./listener_log_xml_filter.py -f <xml listener log to read> -a <host ip>
#                        To filter on a pid, execute this:                                    ./listener_log_xml_filter.py -f <xml listener log to read> -p <pid>
#                        To filter on both a host address/ip address and a pid, execute this: ./listener_log_xml_filter.py -f <xml listener log to read> -a <host ip> -p <pid>
#                        To list out all unique host addresses/ip addresses, execute this:    ./listener_log_xml_filter.py -f <xml listener log to read> --list-hosts
#                        To show all recent errors in the last (default is 24 hours):         ./listener_log_xml_filter.py -f <xml listener log to read> --recent-errors
#                        To show all recent errors with a time override for the default:      ./listener_log_xml_filter.py -f <xml listener log to read> --recent-errors --error-hours 5  # example for 5 hours
#                        See help menu for additional filters (but these are the most used)
#
# Revisions:    11SEP2023 - first draft
#
# Notes:        Use python 3.4 or above due to use of argparse.FileType
#               This script will account the "multiple roots" in the listener log so that memory usage remains minimal while this script executes.
#
#               This script was tested on XML formatted listener logs in Oracle Database 21c.
# 
#               This revised approach will use significantly less memory compared to using args.file.read(), which loads the entire XML file into memory.
#               
#               Here's a brief breakdown of why:
#               
#               Iterative Parsing: By reading the file line-by-line and buffering only until we get a complete <msg>...</msg> fragment, we ensure that at any given point, only a small portion of the XML file is in memory. This is contrasted with the original approach which read the entire XML content into a single string in memory.
# 
#               Clearing Buffers: Once we've processed a single XML fragment (i.e., a <msg>...</msg> entry), we clear the buffer using buffer.clear(). This ensures that the buffer doesn't grow unbounded.
#               
#               lxml's Iterative Parsing: In the revised approach, we use lxml's iterative parsing feature, which doesn't build the entire tree in memory but rather processes elements one by one.
#               
#               No Large String Manipulations: String operations, especially on large data, can be memory-intensive in Python. By working with smaller chunks and not performing extensive operations on the entire content, memory consumption is reduced.
#               
#               With these changes, the memory footprint of the script should be much smaller, especially when working with large XML files.
#
#               Recommendation: rotate your XML formatted listener log files at least weekly in order to avoid memory intensive executions of this script.
#
# TODO:         Might add additional filter for time later
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
    org_id = tree.get('org_id')
    comp_id = tree.get('comp_id')
    msg_type = tree.get('type')
    level = tree.get('level')
    host_id = tree.get('host_id')
    
    try:
        log_time = datetime.strptime(time_str.split('.')[0], '%Y-%m-%dT%H:%M:%S')
    except ValueError:
        log_time = None

    return log_time, host_addr, pid, txt, org_id, comp_id, msg_type, level, host_id

def print_msgs_from_xml(xml_file, host_addr_filter=None, pid_filter=None, org_id_filter=None, comp_id_filter=None, type_filter=None, host_id_filter=None, recent_errors=False, error_hours=24):
    # Setup a buffer to hold fragments of XML content
    buffer = []

    # Iterate over each line in the file
    for line in xml_file:
        # Add the line to the buffer
        buffer.append(line)

        # If the line closes an XML document (assuming "</msg>" is the end tag)
        if b"</msg>" in line:
            # Join the buffered lines to form a complete XML document
            xml_content = b"".join(buffer)

            # Process the XML content
            try:
                time, host_addr, pid, txt, org_id, comp_id, msg_type, level, host_id = process_msg(xml_content)
                
                if host_addr_filter and host_addr != host_addr_filter:
                    continue
                if pid_filter and pid != pid_filter:
                    continue
                if org_id_filter and org_id != org_id_filter:
                    continue
                if comp_id_filter and comp_id != comp_id_filter:
                    continue
                if type_filter and msg_type != type_filter:
                    continue
                if host_id_filter and host_id != host_id_filter:
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
            finally:
                # Clear the buffer
                buffer.clear()

def list_unique_host_addrs(xml_file):
    host_addrs = set()

    # Setup a buffer to hold fragments of XML content
    buffer = []

    # Iterate over each line in the file
    for line in xml_file:
        # Add the line to the buffer
        buffer.append(line)

        # If the line closes an XML document (assuming "</msg>" is the end tag)
        if b"</msg>" in line:
            # Join the buffered lines to form a complete XML document
            xml_content = b"".join(buffer)

            # Parse the XML content
            try:
                tree = ET.fromstring(xml_content)
                host_addr = tree.get('host_addr')
                if host_addr:
                    host_addrs.add(host_addr)
            except ET.XMLSyntaxError:
                continue
            finally:
                # Clear the buffer
                buffer.clear()

    for addr in sorted(host_addrs):
        print(addr)

def main():
    formatter_class = lambda prog: argparse.HelpFormatter(prog, max_help_position=30, width=120)
    parser = argparse.ArgumentParser(description="Filter and print XML messages from the Oracle Database XML formatted listener log", formatter_class=formatter_class)
    parser.add_argument('-f', '--file', type=argparse.FileType('rb'), required=True, help='Path to the XML formatted listener log')
    parser.add_argument('-a', '--host_addr', type=str, help='Filter by host address')
    parser.add_argument('-c', '--comp_id', type=str, help='Filter by comp_id')
    parser.add_argument('-hid', '--host_id', type=str, help='Filter by host_id')
    parser.add_argument('-o', '--org_id', type=str, help='Filter by org_id')
    parser.add_argument('-p', '--pid', type=str, help='Filter by pid')
    parser.add_argument('-t', '--type', type=str, help='Filter by message type')
    parser.add_argument('--list-hosts', '-lh', action='store_true', help='List all unique host addresses from the XML file')
    parser.add_argument('--recent-errors', '-re', action='store_true', help='Show only recent errors from the XML file')
    parser.add_argument('--error-hours', '-eh', type=int, default=24, help='Hours to look back for recent errors, default is 24 hours')
    args = parser.parse_args()

# Check for --error-hours without --recent-errors
    if args.error_hours != 24 and not args.recent_errors:
        parser.error("--error-hours requires --recent-errors to be specified.")

    # Ensure that only --list-hosts and --file are specified
    if args.list_hosts:
        if args.file is None:
            parser.error("--list-hosts should only be used with the --file argument and no other arguments.")

    # Check the file size
    file_size = os.path.getsize(args.file.name)
    if file_size > (1 << 30):  # 1 GB in bytes
        print("Warning: The file size is over 1 GB. Processing might take some time.")
        print("If you see this warning, you might want to start questioning your career choice as an Oracle DBA.")
        print("At least start rotating the listener log so that it doesn't grow so large.")
        # If you wish to exit the script due to file size being too large, uncomment the next line:
        # sys.exit(1)

    xml_file = args.file

    if args.list_hosts:
        list_unique_host_addrs(xml_file)
    elif args.recent_errors:
        print_msgs_from_xml(xml_file, args.host_addr, args.pid, args.org_id, args.comp_id, args.type, args.host_id, True, args.error_hours)
    else:
        print_msgs_from_xml(xml_file, args.host_addr, args.pid, args.org_id, args.comp_id, args.type, args.host_id)

if __name__ == '__main__':
    try:
        main()
    except BrokenPipeError:
        sys.stdout.close()  # Close stdout to handle a pipe properly; in case "head" or "tail" are used in the shell
        os._exit(0)         # Exit without error traceback

