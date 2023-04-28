#!/usr/bin/python3
# Author: Michael Lee
# Title: attention_log_viewer.py
# Oracle Database 21c Attention Log Viewer - 15AUG2022
# https://docs.oracle.com/en/database/oracle/oracle-database/21/admin/diagnosing-and-resolving-problems.html#GUID-633CC0D9-8FA8-4D98-8BE2-967D1CBEE266
#
# Notes: Oracle uses a "psuedo json" format for the attention log in 21c, so some custom parsing on the attention log is used so that Oracle's use of "multiple roots" can be handled correctly with json.loads
# use python 3.4 or above due to use of argparse.FileType
# as of 16AUG2022, the "additional" attention type has not been seen in any example attention log, so hasn't been tested properly
#
 
import sys
import json
from argparse import ArgumentParser
import argparse
 
cl_parser = argparse.ArgumentParser(description='Oracle Database 21c Attention Log Viewer Filter')
cl_parser.add_argument('-f', '--file', default=sys.stdin, type=argparse.FileType('r'), required=True, help='Specify location of attention.log with the full path and filename.')
cl_parser.add_argument('-n', '--attention_type', required=False, type=str.lower, choices=['error', 'warning', 'notification', 'additional'], help='Specify type of notification. Valid values are: Error, Warning, Notification, or Additional')
cl_parser.add_argument('-u', '--urgency', required=False, type=str.lower, choices=['immediate', 'soon', 'deferrable', 'info'], help='Specify type of urgency. Valid values are: Immediate, Soon, Deferrable, or Info')
 
args = cl_parser.parse_args()
log_to_open = args.file.name
 
with open(log_to_open) as log_file_to_read:
    attention_log_contents = log_file_to_read.read() # load the attention_log_contents as string
log_file_to_read.close() # close the attention log before processing

# function to check log file loaded as string
def parse_oracle_json_attention_log(file_content):

    #file_content = self.file_content()

    record_strings = file_content.split("}\n")
    #print("record_strings len: ", len(record_strings))

    for record_string in record_strings:

        if len(record_string) < 1:
            break

        record_string_with_closing_bracket = record_string + "}"
        record_from_json = json.loads(record_string_with_closing_bracket)
        # print(record_from_json)

        if args.attention_type or args.urgency:
            # only print the record(s) that matches the specified attention_type
            if args.attention_type and not args.urgency:
                for key_to_check in record_from_json.keys():
                    if key_to_check.lower() == args.attention_type:
                        for key in record_from_json.keys():
                            value_to_print = key + " : " + record_from_json[key]
                            print(value_to_print)

            # only print the record(s) that matches the specified urgency
            if args.urgency and not args.attention_type:
                for value_to_check in record_from_json.values():
                    if value_to_check.lower() == args.urgency:
                        for key in record_from_json.keys():
                            value_to_print = key + " : " + record_from_json[key]
                            print(value_to_print)

            if args.attention_type and args.urgency:
                # reset these booleans to false with every iteration
                attention_type_matches_key = False
                urgency_matches_value = False
                for key_to_check in record_from_json.keys():
                    if key_to_check.lower() == args.attention_type: 
                        attention_type_matches_key = True
                for value_to_check in record_from_json.values():
                    if value_to_check.lower() == args.urgency:
                        urgency_matches_value = True
                if attention_type_matches_key and urgency_matches_value:
                    for key in record_from_json.keys():
                        value_to_print = key + " : " + record_from_json[key]
                        print(value_to_print)

        else: # else print every record
            for key in record_from_json.keys():
                value_to_print = key + " : " + record_from_json[key]
                print(value_to_print)
        
if args.attention_type or args.urgency:
    pass
else:
    print('Printing all attention log entries.')
    # the above line can be replaced with "pass" if that line is not desired in the output.
    
# call function to dial in on desired events/attention log entries
parse_oracle_json_attention_log(attention_log_contents)
