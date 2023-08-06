# Oracle_Scripts

For those of you Oracle DBAs who work as DoD contractors and need to expedite your Oracle Database STIG related activities, these tools are designed to help you speed up your work.  These were developed and tested with the latest release of the Oracle Database 12c STIG checklist that was released in January of 2023.

You will need a minimum version of Python 3.4 in order to run these.  You will also need the “lxml” module installed in the OS for your Python 3 runtime.  If you don’t have the “lxml” module/library, then request that your sysadmin install it with “pip3 install” as root.

These scripts are similar, but one is more robust than the other.  These scripts are for getting values from the XML formatted Oracle Database STIG checklists that DISA releases.

For example, if you need to know all of the CCI values for a STIG ID or vice versa, both of the scripts can do that by parsing the XML file and providing those values as output.

The “oracle_db_stig_id_cci_list.py” script can only translate between STIG IDs and CCI numbers (and vice versa), but the more robust script, “Oracle_Database_STIG_value_translator.py” script can translate between any value for any item in the checklist to any other value.  In other words, the more robust script can translate from these values:

{CCI, STIG ID, Rule ID, Rule Name, Vuln ID}

And can give you the equivalent values as output.

### attention_log_viewer.py - Python script that can parse out events from the Oracle attention log (attention log is a feature in Oracle Database 21c and above)

### fill_in_host_info_to_oracle_db_checklist.py - used with an XML formatted Oracle Database STIG checklist for filling in the hostname information directly into the ckl file (XML formatted).

### manual_load_STIG_checklist.py - used for direct loading data into the XML formatted Oracle Database STIG checklist for filling in either the Comments, Finding Details, or Status for a STIG ID(Rule_Ver).  Like other scripts, it uses the lxml Python module.  This can be used for building a larger script that will automatically fill in the entire checklist.  It can also be used for manual corrections or additions as needed for a STIG ID.

### oracle_db_stig_id_cci_list.py - Python script that can translate CCI IDs to STIG IDs or STIG IDs to CCI IDs.  This is for use with DISA's XML formatted STIG checklists

### Oracle_Database_STIG_value_translator.py - Python script that can translate any of the following values to its equivalent value: {CCI, STIG ID, Rule ID, Rule Name, Vuln ID}

#

### cleanup_and_disable_auto_stats_advisor_task.ksh - Korn shell script that cleans up the SYSAUX tablespace and the WRI$_ADV_OBJECTS table under the SYS schema.  This is based on this Oracle Document: SYSAUX Tablespace Grows Rapidly After Upgrading Database to 12.2.0.1 or Above Due To Statistics Advisor (Doc ID 2305512.1).  ONLY RUN THIS ONCE.  MAKE SURE TO TEST BEFORE RUNNING.

### datapump_export.ksh - script that uses expdp to export either full database, any selection of schemas, or any selection of tables (if exportable)

### manage_SSO_audit_data.ksh - script that is based on available Oracle documentation on cleaning audit data from databases used for SSO (Single Sign On)

&nbsp;&nbsp;&nbsp;&nbsp; Related Oracle documentation: Oracle Access Manager (OAM) Purging Audit Store Data Where Is The "auditDataPurge.sql" Script Located (Doc ID 2651574.1)

&nbsp;&nbsp;&nbsp;&nbsp; Oracle Access Manager(OAM 11g): What is the Automatic Archiving and Purging Functionality of Audit Data From Database (Doc ID 2255281.1)
