#!/usr/bin/python3
# Author:         Michael Lee
# Created date:   15APR2023
# Title:          Oracle_Database_STIG_value_translator.py
#                 Oracle Database STIG ID to CCI/Rule_ID/Rule_Name/Vul_ID lister/mapper viewer
#
# Notes:          this tool can be used for a quick listing of relationships between STIG IDs to CCIs or any other relationship within the Oracle Database STIG checklist ckl file.
#                 this is used to see the relationship of STIG IDs to CCI values and vice versa
#
#                 This tool is based on the contents of the "Oracle Database 12c Security Technical Implementation Guide", "Release: 6 Benchmark Date: 26 Jan 2023" XML formatted checklist file (*.ckl)
#
#                 Printing CCI values are handled a little differently because some STIG IDs have multiple CCI numbers.
#
#                 Use python 3.4 or above due to use of argparse.FileType
#
# Instructions:   Load the XML formatted ckl file for the Oracle Database 12c checklist on to your OS and then use this tool to view mappings between the various values that can be seen in the checklist.
#                 Example: To view all of the CCI values for a STIG ID, execute this:      ./Oracle_Database_STIG_value_translator.py -f <ckl_file> -s <STIG ID> -t cci
#                          To view all of the STIG ID values for a CCI, then execute this: ./Oracle_Database_STIG_value_translator.py -f <ckl_file> -c <CCI> -t stig
#
# Revisions:      20APR2023 - Added format check if the -c option is used for a CCI ID.
#                 14OCT2023 - modified the command line options to be a little easier to use when using the mandatory -t option.
#

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

cl_parser = argparse.ArgumentParser(description='Oracle Database <STIG ID|CCI|Rule ID|Rule Name|Vuln ID> lister/mapper viewer')
cl_parser.usage = '''This program translates any of the following values to its equivalent.  <STIG ID>, <CCI ID>, <Rule ID>, <Rule Name>, <Vuln ID>

 Usage: Oracle_Database_STIG_value_translator.py -f <ckl file> < -s <STIG ID> or -c <CCI> or -ri <Rule ID> or -rn <Rule Name> or -v <Vuln ID> > -t <STIG ID|CCI|Rule ID|Rule Name|Vuln ID>
       
 Note: when using -t and the desired value type to convert to, the use of double quotes around the type might be needed.
 Examples: ./Oracle_Database_STIG_value_translator.py -f <ckl file> -v V-237723 -t "vuln id"
           ./Oracle_Database_STIG_value_translator.py -f <ckl file> -v V-237723 -t "stig id"
           ./Oracle_Database_STIG_value_translator.py -f <ckl file> -v V-237723 -t "rule id"
           ./Oracle_Database_STIG_value_translator.py -f <ckl file> -v V-237723 -t "rule name"
		  '''
cl_parser.add_argument('-f', '--file', default=sys.stdin, type=argparse.FileType('r'), required=True, help='Specify location of XML formatted STIG ckl file with the full path and filename.')
cl_parser.add_argument('-c', '--cci', required=False, type=str.upper, help='Specify value of CCI.')
cl_parser.add_argument('-ri', '--rule_id', required=False, type=str, help='Specify value of Rule ID.')
cl_parser.add_argument('-rn', '--rule_name', required=False, type=str.upper, help='Specify value of Rule Name.')
cl_parser.add_argument('-s', '--stig', required=False, type=str.upper, help='Specify value of STIG ID.', metavar='STIG/STIG ID')
cl_parser.add_argument('-v', '--vul', required=False, type=str.upper, help='Specify value of Vul ID.', metavar='VUL/VULN/Vuln ID')
cl_parser.add_argument('-t', '--translate_to', required=True, type=str.lower, choices=['cci', 'rule_id', 'rule id', 'rule_name', 'rule name', 'stig', 'stig id', 'vul', 'vuln', 'vuln id'], help='Specify value of the equivalent value to translate to.')

args = cl_parser.parse_args()

# check to make sure that not too command line many arguments were used
# only 1 optional value type is allowed - choices are only one of the following: -c or --cci, -ri or --rule_id, -rn or --rule_name, -s or --stig, -v or --vul
def check_arg_count(expected_arg_count):
    if len(sys.argv) > expected_arg_count + 1:
        print(expected_arg_count)
        print(f"Too many arguments. Expected {expected_arg_count} arguments, but got {len(sys.argv) - 1} arguments.")
        print("Error: Too many command line arguments specified. Please provide no more than 1 optional arguments.")
        print("The choices are: -c or --cci, -ri or --rule_id, -rn or --rule_name, -s or --stig, -v or --vul")
        sys.exit(1)
# check for 6 arguments - -f or file <file name>, -c or --cci, -ri or --rule_id, -rn or --rule_name, -s or --stig, -v or --vul <optional value to translate from>, -t <value type to translate to>
check_arg_count(6)

# Check that at least one of the options in the list was specified
if not any([args.cci, args.rule_id, args.rule_name, args.stig, args.vul]):
    print("Error: Please specify at least one of the following options: -c or --cci, -ri or --rule_id, -rn or --rule_name, -s or --stig, -v or --vul.")
    sys.exit(1)
 
# check for nothing to translate within the checklist
# in other words, check for human error on the command line with incorrectly specified command line options

# function to display command line specification error
def show_nothing_to_translate_error_and_exit(error_message):
    print(f"ERROR: {error_message}", file=sys.stderr)
    sys.exit(1)

# function for checking argument contents
def is_arg_specified(arg):
    return arg is not None and arg != ''

# Convert multi-word choices to single-word equivalents for easy comparison
translate_to_equivalents = {
    'rule id': 'rule_id',
    'rule name': 'rule_name',
    'stig id': 'stig',
    'vuln': 'vul',
    'vuln id': 'vul'
}

# If the choice is a multi-word string, get its single-word equivalent
args.translate_to = translate_to_equivalents.get(args.translate_to, args.translate_to)

# Define a dictionary to map 'translate_to' choices to their corresponding args
args_to_check = {
    'cci': args.cci,
    'rule_id': args.rule_id,
    'rule_name': args.rule_name,
    'stig': args.stig,
    'vul': args.vul
}

# Check if the same arg is being specified as the 'translate_to' choice
if is_arg_specified(args_to_check[args.translate_to]):
    show_nothing_to_translate_error_and_exit(f"'{args_to_check[args.translate_to]}' should not be specified when 'translate_to' or -t is set to '{args.translate_to}'.")

file_to_open = args.file.name
xml_filename = file_to_open
xml_parser = ET.XMLParser(encoding='utf-8', recover=True)
xml_tree = ET.parse(xml_filename, parser=xml_parser)
xml_root = xml_tree.getroot()

def is_valid_cci(cci):
    pattern = r"^CCI-\d{6}$"
    return bool(re.match(pattern, cci))

# Check which optional argument was specified
if is_arg_specified(args.cci):
    specified_arg = args.cci
    if not is_valid_cci(specified_arg):
        print("Error: The CCI value is not in the correct format. It must be in the format of CCI-###### (six digits).")
        sys.exit(1)
if is_arg_specified(args.rule_id):
    specified_arg = args.rule_id
if is_arg_specified(args.rule_name):
    specified_arg = args.rule_name
if is_arg_specified(args.stig):
    specified_arg = args.stig
if is_arg_specified(args.vul):
    specified_arg = args.vul

if args.translate_to == 'cci':
    if is_arg_specified(args.rule_id):
        xpath_query = f"//VULN[STIG_DATA[VULN_ATTRIBUTE='Rule_ID' and ATTRIBUTE_DATA='{specified_arg}']]/STIG_DATA[VULN_ATTRIBUTE='CCI_REF']"
    if is_arg_specified(args.rule_name):
        xpath_query = f"//VULN[STIG_DATA[VULN_ATTRIBUTE='Group_Title' and ATTRIBUTE_DATA='{specified_arg}']]/STIG_DATA[VULN_ATTRIBUTE='CCI_REF']"
    if is_arg_specified(args.stig):
        xpath_query = f"//VULN[STIG_DATA[VULN_ATTRIBUTE='Rule_Ver' and ATTRIBUTE_DATA='{specified_arg}']]/STIG_DATA[VULN_ATTRIBUTE='CCI_REF']"
    if is_arg_specified(args.vul):
        xpath_query = f"//VULN[STIG_DATA[VULN_ATTRIBUTE='Vuln_Num' and ATTRIBUTE_DATA='{specified_arg}']]/STIG_DATA[VULN_ATTRIBUTE='CCI_REF']"

    cci_refs = []

    for elem in xml_tree.xpath(xpath_query):
        cci_refs.append(elem.find("ATTRIBUTE_DATA").text)

    if len(cci_refs) > 1:
        print(f"{', '.join(cci_refs)}")
    elif len(cci_refs) == 1:
        print(f"{cci_refs[0]}")
    #else:
    #    print(f"No CCI_REF values were found for Rule_Ver/STIG ID '{args.stig}'.")

def find_vulns(xml_root, specified_arg):
    # Find all VULN elements that contain the specified argument
    xpath_query = "//VULN[STIG_DATA[ATTRIBUTE_DATA='" + specified_arg + "']]"
    vulns = xml_root.xpath(xpath_query)
    return vulns

if args.translate_to == 'stig':
    # Find all VULN elements that contain the specified argument
    vulns = find_vulns(xml_root, specified_arg)
    
    # Loop through each VULN element and find the Rule_Ver/STIG ID attribute value
    for vuln in vulns:
        rule_ver = vuln.xpath("STIG_DATA[VULN_ATTRIBUTE='Rule_Ver']/ATTRIBUTE_DATA")[0].text
        print(rule_ver)

if args.translate_to == 'rule_id':
    # Find all VULN elements that contain the specified argument
    vulns = find_vulns(xml_root, specified_arg)
    
    # Loop through each VULN element and find the Rule_ID attribute value
    for vuln in vulns:
        rule_id = vuln.xpath("STIG_DATA[VULN_ATTRIBUTE='Rule_ID']/ATTRIBUTE_DATA")[0].text
        print(rule_id)

if args.translate_to == 'rule_name':
    # Find all VULN elements that contain the specified argument
    vulns = find_vulns(xml_root, specified_arg)
    
    # Loop through each VULN element and find the Rule_ID attribute value
    for vuln in vulns:
        rule_name = vuln.xpath("STIG_DATA[VULN_ATTRIBUTE='Group_Title']/ATTRIBUTE_DATA")[0].text
        print(rule_name)

if args.translate_to == 'vul' or args.translate_to == 'vuln' or args.translate_to == 'vuln id':
    # Find all VULN elements that contain the Rule_Ver/STIG ID value
    vulns = find_vulns(xml_root, specified_arg)
    
    # Loop through each VULN element and find the Vuln_Num attribute value
    for vuln in vulns:
        vuln_num = vuln.xpath("STIG_DATA[VULN_ATTRIBUTE='Vuln_Num']/ATTRIBUTE_DATA")[0].text
        print(vuln_num)

# this dumps the entire XML file
# can be uncommented for debug output
#children = root_element_of_xml.getchildren() #for child in children:
#    ET.dump(child)

sys.exit(0)
