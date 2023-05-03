#!/usr/bin/python3
# Author:         Michael Lee
# Created date:   4MAY2023
# Title:          manual_load_STIG_checklist.py
#                 Oracle Database STIG checklist loader
#
# Notes:          This tool can be used for manually loading values for a STIG ID within the XML formatted Oracle Database STIG checklist ckl file.
#
#                 This tool is based on the contents of the "Oracle Database 12c Security Technical Implementation Guide", "Release: 6 Benchmark Date: 26 Jan 2023" XML formatted checklist file (*.ckl)
#                 This will also work on previous versions of the checklist, going back to Version 2, Release 1.
#
#                 Use Python 3.4 or above due to use of argparse.FileType and the use of lxml with method="c14n"
#
# Instructions:   Load the XML formatted ckl file for the Oracle Database 12c checklist on to your OS and then use this tool to view mappings between the various values that can be seen in the checklist.
#                 Example: To update the Status for a STIG ID, execute this:          ./manual_load_STIG_checklist.py -l <ckl_file> -i <STIG ID> -s <NotAFinding | Open | NotApplicable>
#                          To update the Comments for a STIG ID, execute this:        ./manual_load_STIG_checklist.py -l <ckl_file> -f <txt file to load for Comments> -i <STIG ID> --comments
#                          To update the Finding Details for a STIG ID, execute this: ./manual_load_STIG_checklist.py -l <ckl_file> -f <txt file to load for Comments> -i <STIG ID> --finding_details
#
# Revisions:      3MAY2023 - first draft
#

import argparse
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

cl_parser = argparse.ArgumentParser(description='Oracle Database STIG Checklist Manual Loader Tool')
cl_parser.usage = '''This program can load one of 3 fields for a STIG ID within the XML formatted Oracle Database STIG checklist.

manual_load_STIG_checklist.py -f <file to load from> -l <ckl_file> -f <txt file to load from> -s <STIG ID> -s|-c|-d
Note: the -f or --loadfromfile option is only used with the -c or -d options.

'''
cl_parser.add_argument('-f', '--loadfromfile', default=None, type=argparse.FileType('r'), required=False, help='Specify location of txt file with the related data (Finding Details or Comments).')
cl_parser.add_argument('-l', '--checklist', default=None, type=argparse.FileType('r+'), required=True, help='Specify location of ckl file that is the XML formatted Oracle Database STIG checklist.')
cl_parser.add_argument('-d', '--finding_details', required=False, action='store_true', help='Specify if loading the file to the Finding Details for a STIG ID.')
cl_parser.add_argument('-i', '--id', '--rule_ver', required=True, type=str.upper, help='Specify value of STIG ID.')
cl_parser.add_argument('-c', '--comments', required=False, action='store_true', help='Specify if loading the file to the Comments for a STIG ID.')
cl_parser.add_argument('-s', '--status', required=False, type=str, choices=['NotAFinding', 'Open', 'NotApplicable'], help='Specify if updating the status for a STIG ID')
args = cl_parser.parse_args()

# sanity checks for command line options
# Check if at least one of the following options has been used: --finding_details, --comments, or --status
if not (args.finding_details or args.comments or args.status):
    cl_parser.error("\n\nError: At least one of the following options must be specified: --finding_details, --comments, or --status\nPlease specify one of the following: --finding_details or -d, --comments or -c, --status or -s")

# Check that no file is specified with -f or --loadfromfile if the -s or --status option is used
if args.status and args.loadfromfile:
    cl_parser.error("\n\nError: Do not specify a file with the -f or --loadfromfile option when using the -s or --status option.")
	
# Check that only one of the -d, -c, and -s options has been specified
if sum([bool(args.finding_details), bool(args.comments), bool(args.status)]) != 1:
    cl_parser.error("\n\nError: Only one of the following options can be specified: -d/--finding_details, -c/--comments, or -s/--status")

# Check that the -f option has been used if the -c(--comments) or -d(--finding_details) option has been used
if args.comments and not args.loadfromfile or args.finding_details and not args.loadfromfile:
    cl_parser.error("\n\nError: The -f or --loadfromfile option must be used with the -c/--comments or the -d/--finding_details options.")

# loaded from -l or --checklist
xml_filename = args.checklist
xml_parser = ET.XMLParser(encoding='utf-8', recover=True)
xml_tree = ET.parse(xml_filename, parser=xml_parser)
xml_root = xml_tree.getroot()

# Check if the specified STIG ID exists in the XML file
if not any(vuln.findtext('.//VULN_ATTRIBUTE[.="Rule_Ver"]/../ATTRIBUTE_DATA') == args.id for vuln in xml_root.findall('.//VULN')):
    cl_parser.error(f"\n\nError: STIG ID {args.id} not found in the specified XML file.")

# Update the ckl file based on the Rule_Ver value
for vuln in xml_root.findall('.//VULN'):
    rule_ver = vuln.findtext('.//VULN_ATTRIBUTE[.="Rule_Ver"]/../ATTRIBUTE_DATA')
    if rule_ver == args.id:
        if args.status:
            status = vuln.find('STATUS')
            status.text = args.status
            print('The STATUS has been updated to ' + args.status + ' for STIG ID ' + args.id)

        if args.comments:
            comments = vuln.find('COMMENTS')
            comments.text = args.loadfromfile.read()
            print(f"The COMMENTS have been updated for {args.id} from file {args.loadfromfile.name}")

        if args.finding_details:
            finding_details = vuln.find('FINDING_DETAILS')
            finding_details.text = args.loadfromfile.read()
            print(f"The FINDING_DETAILS have been updated for {args.id} from file {args.loadfromfile.name}")

        break

xml_tree.write(args.checklist.name, method="c14n")

# this dumps the entire XML file
# can be uncommented for debug output
#children = root_element_of_xml.getchildren() #for child in children:
#    ET.dump(child)

sys.exit(0)
