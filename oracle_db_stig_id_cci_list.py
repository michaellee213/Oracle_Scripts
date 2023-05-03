#!/usr/bin/python3
# Author:         Michael Lee
# Created date:   15APR2023
# Title:          oracle_db_stig_id_cci_list.py
#                 Oracle Database STIG ID to CCI ID/CCI ID to STIG ID lister/mapper viewer
#                 
# Notes:          this is used to see the relationship of STIG IDs to CCI values and vice versa
#                 use python 3.4 or above due to use of argparse.FileType
#
#                 This tool is based on the contents of the "Oracle Database 12c Security Technical Implementation Guide", "Release: 6 Benchmark Date: 26 Jan 2023" XML formatted checklist file (*.ckl)
#
#                 Printing CCI values are handled a little differently because some STIG IDs have multiple CCI numbers.
#
# Instructions:   Load the XML formatted ckl file for the Oracle Database 12c checklist on to your OS and then use this tool to view mappings between the various values that can be seen in the checklist.
#                 Example: To view all of the CCI values for a STIG ID, execute this:      ./Oracle_Database_STIG_value_translator.py -f <ckl_file> -s <STIG ID>
#                          To view all of the STIG ID values for a CCI, then execute this: ./Oracle_Database_STIG_value_translator.py -f <ckl_file> -c <CCI>
#
# Revisions:     20APR2023 - Added format check if the -c option is used for a CCI ID.
#

import os
import re
import sys
try:
    from lxml import etree as ET
except ImportError:
    print("Error: The 'lxml' module is not available. Please install it using 'pip3 install lxml' or 'pip install lxml' and try again.")
    sys.exit(1)
from argparse import ArgumentParser
import argparse

MIN_PYTHON_VERSION = (3, 4)  #set your minimum Python version here
if sys.version_info < MIN_PYTHON_VERSION:
    print(f"Error: Python {MIN_PYTHON_VERSION[0]}.{MIN_PYTHON_VERSION[1]} or higher is required to run this script.")
    sys.exit(1)

cl_parser = argparse.ArgumentParser(description='Oracle Database STIG ID to CCI/CCI to STIG ID lister/mapper viewer')
cl_parser.usage = "This program translates STIG IDs to CCI IDs and vice versa. Usage: oracle_db_stig_id_cci_list.py -f <ckl file> -c <CCI> or -s <STIG ID>"
cl_parser.add_argument('-f', '--file', default=sys.stdin, type=argparse.FileType('r'), required=True, help='Specify location of XML formatted STIG ckl file with the full path and filename.')
cl_parser.add_argument('-c', '--cci', required=False, type=str.upper, help='Specify value of CCI.')
cl_parser.add_argument('-s', '--stig', required=False, type=str.upper, help='Specify value of STIG ID.')
 
args = cl_parser.parse_args()
file_to_open = args.file.name

# check for both cci and stig specified on the command line
# abort script if both are specified
if args.stig and args.cci:
    sys.exit('Please only specify either a STIG ID or a CCI value, but not both.')

xml_filename = file_to_open
xml_parser = ET.XMLParser(encoding='utf-8', recover=True)
xml_tree = ET.parse(xml_filename, parser=xml_parser)
xml_root = xml_tree.getroot()
 
if args.stig:
    #print('STIG ID specified.  Looking up CCI.')

    xpath_query = f"//VULN[STIG_DATA[VULN_ATTRIBUTE='Rule_Ver' and ATTRIBUTE_DATA='{args.stig}']]/STIG_DATA[VULN_ATTRIBUTE='CCI_REF']"

    cci_refs = []

    for elem in xml_tree.xpath(xpath_query):
        cci_refs.append(elem.find("ATTRIBUTE_DATA").text)

    if len(cci_refs) > 1:
        print(f"{', '.join(cci_refs)}")
    elif len(cci_refs) == 1:
        print(f"{cci_refs[0]}")
    else:
        print(f"No CCI_REF values were found for Rule_Ver/STIG ID '{args.stig}'.")

def is_valid_cci(cci):
    pattern = r"^CCI-\d{6}$"
    return bool(re.match(pattern, cci))

if args.cci:
    #print('CCI specified.  Looking up STIG ID.')
    
    if not is_valid_cci(args.cci):
        print("Error: The CCI value is not in the correct format. It must be in the format of CCI-###### (six digits).")
        sys.exit(1)

    # Find all VULN elements that contain the CCI_REF value
    vulns = xml_root.xpath("//VULN[STIG_DATA[ATTRIBUTE_DATA='" + args.cci + "']]")
    
    # Loop through each VULN element and find the Rule_Ver/STIG ID attribute value
    for vuln in vulns:
        rule_ver = vuln.xpath("STIG_DATA[VULN_ATTRIBUTE='Rule_Ver']/ATTRIBUTE_DATA")[0].text
        print(rule_ver)
                            
# this dumps the entire XML file
# can be uncommented for debug output
#children = root_element_of_xml.getchildren() #for child in children:
#    ET.dump(child)

sys.exit(0)
