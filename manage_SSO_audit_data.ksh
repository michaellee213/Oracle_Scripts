#!/bin/ksh
# Title:        manage_SSO_audit_data.ksh
# Purpose:      This script will automatically manage audit data for the SSO databases, based on a default retention of 370 days for the affected tables.
#
# Usage:        manage_SSO_audit_data.ksh
#               crontab: 5 * * * * /opt/oracle/admin/scripts/manage_SSO_audit_data.ksh > /var/tmp/manage_SSO_audit_data.ksh.log 2>&1
#               Runs this every hour at the 5 minute mark.
#
# Author:       Michael Lee
# Created on:   5AUG2023
#
# Notes:        Both traditional single instance and pdb/cdb architecture is supported.
#
#               The SQL in this script is based on Oracle provided scripts for Oracle Fusion Middleware that are intended to manage built up audit data
#
#               Related Oracle documentation: Oracle Access Manager (OAM) Purging Audit Store Data Where Is The "auditDataPurge.sql" Script Located (Doc ID 2651574.1)
#                                             Oracle Access Manager(OAM 11g): What is the Automatic Archiving and Purging Functionality of Audit Data From Database (Doc ID 2255281.1)
#
#               This script will determine what the oldest day is between the 2 largest tables, IAU_COMMON and IAU_CUSTOM.
#               Once that number of days is known, then that will be used in a countdown fashion to clean the tables until the retention number has been reached.
#               This is done so that cleaning of audit tables, even when large, over 100+ GB, will not produce a ballooneed/inflated UNDO tablespace.
#               This is also so that the job doesn't hang for an inordinate amount of time.
#
#               The index for the "pid_list" might need to be adjusted (on or near line 70) so that detection of a previously running instance of this script is detected correctly.
#
# Revisions:    5AUG2023 - first draft
#                           
# Instructions: Deploy to one of the SSO database servers so that audit data from the Middle tier can be managed by this script.
#               This script will automatically clean the affected tables up to the retention period.
#               Make sure that the ADR_BASE and ORACLE_BASE is set appropriately in this script on the database server.
#               Adjust the values in this script for the ADR_BASE and ORACLE_BASE as needed for your database server.
#               You must run this script on either the Linux, SunOS platforms.
#
#               This script can be implemented in the crontab, OEM, or Cloud Control
#               Don't forget to convert the EOL format to Linux/Unix
#
#               In Notepad++, Edit, EOL Conversion (or)
#
#               vi manage_SSO_audit_data.ksh
#               :set ff=unix
#               :wq
#
# Runtime:      As of 5AUG2023, the runtime for this job is less than 1 hour.
#
# Size:         The produced log files won't accumulate since they are overwritten on every execution of this script.
#########################################################################################

#set -x

on_call_email_address="youremail@domain.com"

host_name=$(hostname | cut -d'.' -f1)
timestamp_now=$(date)

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin:/usr/ucb
export PATH

# first check for other running process of this script
# load array and then check index 3 to see if it was loaded; if it was loaded, then abort
ps -ef | grep ${0} | grep -v grep | { \
  pid_index=0;
  set -A pid_list
  while read pid
  do
    pid_list[$pid_index]=$pid
    let pid_index=$pid_index+1
  done;
}

if [[ ! -z ${pid_list[3]} ]]; then
  echo "Host name: $host_name"
  echo "Timestamp: $timestamp_now"
  echo "There is another instance of ${0} running."
  echo "The previous run of the ${0} script is still executing and this execution was aborted."
  (
  echo "Host name: $host_name"
  echo "Timestamp: $timestamp_now"
  echo "There is another instance of ${0} running."
  echo "The previous run of the ${0} script is still executing and this execution was aborted."
  ) | mailx -s "Problem with ${0} script detected." $on_call_email_address
echo "Aborting script..."
exit 1
fi

ostype=$(uname)
# SANITY CHECKS
if [[ $ostype = "SunOS" ]]; then
  ORATAB="/var/opt/oracle/oratab"
else
  ORATAB="/etc/oratab"
fi
if [[ ! -f $ORATAB ]]; then
  echo "No oratab file found!"
  echo "Exiting..."
  exit 1
fi
#Make sure that the oratab is populated with at least one entry
ORACLE_HOME_ORATAB_CHECK=$(grep -i ^[0-9a-zA-Z] $ORATAB | sed 1q | cut -f2 -d:)
if [[ $ORACLE_HOME_ORATAB_CHECK = "" ]]; then
  echo "The oratab file located at $ORATAB is not populated with any entries.  The ${0} script has been aborted."
  echo "The oratab file located at $ORATAB is not populated with any entries.  The ${0} script has been aborted." | mailx -s "The oratab file is empty" $on_call_email_address
  exit 1
fi

# build array of all ORACLE_SID values; will be used for all conditions, command line options present or not
#ps -ef | grep ora_pmon | grep -v 'grep' | grep 'oracle' | awk '{print $NF}' | sed 's-ora_pmon_--' | grep -v 's---' | { \

cat $ORATAB | sed '/^$/d' | grep -v ^'#' | awk -F: '{print $1}' | sort -u | { \
  oracle_sid_list_index=0;
  set -A ORACLE_SID_LIST
  while read ORACLE_SID_LIST_PROCESSES
  do
    ORACLE_SID_LIST[$oracle_sid_list_index]=$ORACLE_SID_LIST_PROCESSES
    let oracle_sid_list_index=$oracle_sid_list_index+1
  done;
}

# Check that the OS user is oracle
USERID=$(whoami)
if [ $? -ne 0 ]; then
  echo "ERROR: unable to determine uid"
  echo "Exiting..."
  exit 1
fi

if [[ "${USERID}" != "oracle" ]]; then
  echo "ERROR: This script must be run as the oracle user."
  echo "Exiting..."
  exit 1
fi

# FUNCTIONS
clean_environment () {
# unset all default environment variables
env | grep -v ^'HOME' | awk -F'=' '{print $1}' | grep -v 'disable_email_alerting' | grep -v 'ORACLE_BASE_override' | grep -v 'specified_container_database' | grep -v 'specified_pluggable_database' | grep -v 'retention_period_in_days_override' | grep -v 'retention_period_for_audit_data_in_days' | grep -v 'user_to_clean_audit_data' | while read var
do
  unset $var
done
# Do not error on unset environment variables during substitution
set +u
return
}

set_environment () {
clean_environment
on_call_email_address="youremail@domain.com"
PATH=/usr/bin:/bin:/usr/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin
export PATH
TODAY=$(date "+%d%b%Y")
export TODAY
TODAY_WITH_SECONDS=$(date "+%d%b%Y_%H%M%S")
export TODAY_WITH_SECONDS
# dynamic environment variable definitions
ostype=$(uname)
host=$(hostname | cut -d'.' -f1)
# SANITY CHECKS
if [[ $ostype = "SunOS" ]]; then
  ORATAB="/var/opt/oracle/oratab"
else
  ORATAB="/etc/oratab"
fi
if [[ ! -f $ORATAB ]]; then
  echo "No oratab file found!"
  echo "Exiting..."
  exit 1
fi
#Make sure that the oratab is populated with at least one entry
ORACLE_HOME_ORATAB_CHECK=$(grep -i ^[0-9a-zA-Z] $ORATAB | sed 1q | cut -f2 -d:)
if [[ $ORACLE_HOME_ORATAB_CHECK = "" ]]; then
  echo "The oratab file located at $ORATAB is not populated with any entries.  The ${0} script has been aborted."
  echo "The oratab file located at $ORATAB is not populated with any entries.  The ${0} script has been aborted." | mailx -s "The oratab file is empty" $on_call_email_address
  exit 1
fi

# check for duplicate ORACLE_SID values in oratab
# Note: this might not work in AIX and will need to be commented out.
cat $ORATAB | sed '/^$/d' | grep -v ^'#' | awk -F: '{print $1}' | sort -u | while read db_sid
do
  cat $ORATAB | sed '/^$/d' | grep -v ^'#' | grep $db_sid | awk -F: '{print $1}' | tr ' ' '\n' | { \
    oratab_entry_index=0;
    set -A ORATAB_LIST
    while read ora_entry
    do
      ORATAB_LIST[$oratab_entry_index]=$ora_entry
      let oratab_entry_index=$oratab_entry_index+1
    done;
    }
  
  typeset -i ORACLE_SID_duplicate_check_count
  ORACLE_SID_duplicate_check_count=0
  
  for oratab_entry in ${ORATAB_LIST[@]}
  do
    if [[ "${oratab_entry}" = "${db_sid}" ]];then
      ORACLE_SID_duplicate_check_count=$ORACLE_SID_duplicate_check_count+1
      if (( $ORACLE_SID_duplicate_check_count > 1 ));then
        echo "The $db_sid ORACLE_SID value was detected in the oratab file more than once."
        echo "The execution of the ${0} script was aborted."
        echo "Remove the duplicate entry in oratab and run the ${0} script again."
        (
        echo "The $db_sid ORACLE_SID value was detected in the oratab file more than once."
        echo "The execution of the ${0} script was aborted."
        echo "Remove the duplicate entry in oratab and run the ${0} script again."
        ) | mailx -s "Duplicate entry for $db_sid on $host" $on_call_email_address
        exit 1
      fi
    fi  
  done  
done
HOME_FOLDER=$(cd;pwd)
ORACLE_SID=$1
ORAENV_ASK="NO"
export ORAENV_ASK ORACLE_SID
echo "ORACLE_SID=${ORACLE_SID}"
# get first oracle home from oratab
#ORACLE_HOME=$(grep $'${ORACLE_SID}' $ORATAB | sed 1q | cut -f2 -d:)
PATH=/usr/bin:/bin:/usr/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin
ORACLE_HOME=$(cat $ORATAB | grep -v ^'#' | grep -w "$ORACLE_SID": | cut -d ':' -f 2)
PATH=$PATH:$ORACLE_HOME/bin:$ORACLE_HOME/perl/bin:$ORACLE_HOME/jdk/bin:$ORACLE_HOME/OPatch
. oraenv
export ORACLE_HOME
LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib:/lib
export PATH LD_LIBRARY_PATH
# this seems to be a universal location regardless of the platform used for ADR_BASE and ORACLE_BASE
# the diagnostic_dest parameter in every database listed in the Oracle home will be checked for redundancy
# make sure to change this if your environment has different values
ADR_BASE="/var/opt/oracle"
export ADR_BASE
if [[ -n $ORACLE_BASE_override ]];then
  ORACLE_BASE=$ORACLE_BASE_override
else
  ORACLE_BASE="/opt/oracle"
fi
# trim trailing slash from ORACLE_BASE
ORACLE_BASE=${ORACLE_BASE%/}
export ORACLE_BASE
TMP=/tmp;TEMP=/tmp;TMPDIR=/tmp
export TMP TEMP TMPDIR
SSO_CLEAN_AUDIT_DATA_DATE_lowercase=`date +%d%b%Y_%H%M%S`
check_for_binary cut
month_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase=$(echo $SSO_CLEAN_AUDIT_DATA_DATE_lowercase | cut -b 3-5)
day_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase=$(echo $SSO_CLEAN_AUDIT_DATA_DATE_lowercase | cut -b 1-2)
year_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase=$(echo $SSO_CLEAN_AUDIT_DATA_DATE_lowercase | cut -b 6-9)
hour_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase=$(echo $SSO_CLEAN_AUDIT_DATA_DATE_lowercase | cut -b 11-12)
minute_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase=$(echo $SSO_CLEAN_AUDIT_DATA_DATE_lowercase | cut -b 13-14)
second_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase=$(echo $SSO_CLEAN_AUDIT_DATA_DATE_lowercase | cut -b 15-16)
# convert to uppercase
case "$month_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase" in
    "Jan") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="JAN";;
    "Feb") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="FEB";;
    "Mar") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="MAR";;
    "Apr") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="APR";;
    "May") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="MAY";;
    "Jun") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="JUN";;
    "Jul") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="JUL";;
    "Aug") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="AUG";;
    "Sep") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="SEP";;
    "Oct") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="OCT";;
    "Nov") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="NOV";;
    "Dec") month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized="DEC";;
esac
# SSO_CLEAN_AUDIT_DATA_DATE with capital letters for months
SSO_CLEAN_AUDIT_DATA_DATE=$(echo "$day_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase$month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized$year_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase-${hour_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase}:${minute_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase}:${second_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase}")
# remove trailing slash
SSO_CLEAN_AUDIT_DATA_DATE=${SSO_CLEAN_AUDIT_DATA_DATE%/}
export SSO_CLEAN_AUDIT_DATA_DATE

SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES=$(echo "$day_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase$month_from_SSO_CLEAN_AUDIT_DATA_DATE_capitalized$year_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase-${hour_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase}_${minute_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase}_${second_from_SSO_CLEAN_AUDIT_DATA_DATE_lowercase}")
#remove trailing slash
SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES=${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES%/}
export SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES

LOGDIR="/var/tmp"
# trim trailing slash from LOGDIR
LOGDIR=${LOGDIR%/}
if [[ ! -d $LOGDIR ]];then
  echo "The LOGDIR path: $LOGDIR path doesn't exist."
  exit 1
fi

LOG_DIR_RETENTION_IN_DAYS=30
export LOG_DIR_RETENTION_IN_DAYS

if [[ -n $retention_period_in_days_override ]];then
  typeset -i retention_period_for_audit_data_in_days
  retention_period_for_audit_data_in_days=$retention_period_in_days_override
else
  typeset -i retention_period_for_audit_data_in_days
  retention_period_for_audit_data_in_days=370
fi
#typeset -x retention_period_for_audit_data_in_days
export retention_period_for_audit_data_in_days

return
}

usage (){
  echo ""
  echo "Usage: ${0} <options>"
  echo ""
  echo " -c  MANDATORY: if this is specified, then this single instance/container database will be checked"
  echo "                use only this option if the database is using traditional architecture and not cdb/pdb"
  echo ""
  echo " -u  MANDATORY: specify user/schema that contains the tables to be pruned"
  echo ""
  echo " -p   OPTIONAL: if this is specified, then this pluggable database will be checked"
  echo "                this option must be used with the -c option"
  echo ""
  echo " -d   OPTIONAL: this will disable e-mail alerts"
  echo "                and can be used on the command line"
  echo "                for testing before this script is deployed as a scheduled job."
  echo ""
  echo " -r   OPTIONAL: specify a custom retention period; value is in days"
  echo "                default value is 370 days"
  echo ""
  echo " -o   OPTIONAL: this will override the default value for the ORACLE_BASE"
  echo "                this is usually a higher folder in the path for the ORACLE_HOME (usually /opt/oracle or /u01/oracle)"
  echo "                example: \"-o /opt/oracle\" or \"-o /u01/oracle\""
  echo ""
  echo " -h             shows this help"
  echo ""
}

typeset -i retention_period_for_audit_data_in_days
retention_period_for_audit_data_in_days=370
typeset -x SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES

while getopts "c:dho:p:r:u:" options;do
  case $options in
  c  ) specified_container_database=$OPTARG ;; #enable the checking of a specified container database
  d  ) disable_email_alerting=1 ;; #e-mail alerting always on by default; this disables it
  o  ) ORACLE_BASE_override=$OPTARG ;; #override the default value for the ORACLE_BASE
  p  ) specified_pluggable_database=$OPTARG ;; #enable the checking of a specified pluggable database; must be used with -c
  r  ) retention_period_in_days_override=$OPTARG ;; # custom retention period in days for the audit data
  u  ) user_to_clean_audit_data=$OPTARG ;; #specify the user/schema that contains the tables to be pruned
  h  ) usage; exit 0;;
  *  ) echo "Unimplemented option. -$OPTARG" >&2; usage; exit 1;;
  esac
done

# validate command line options
if [[ -n $specified_pluggable_database ]] && [[ -z $specified_container_database ]];then
  usage
  echo "A pluggable database has been specified without its container."
  echo "If you would like to check a pluggable database, then please specify a container database along with a SID for the container database."
  exit 1
fi

if [[ -n $ORACLE_BASE_override ]];then
  if [[ ! -d $ORACLE_BASE_override ]];then
    usage
    echo "The directory specified with the -o option doesn't exist."
    echo "If you are trying to specify a directory for the ORACLE_BASE value, then make sure the directory exists.  Exiting..."
    exit 1
  else
    echo "The -o option has been used."
    echo "The default value for the ORACLE_BASE has been replaced with the value of: $ORACLE_BASE_override"
  fi
fi

# check for the container ORACLE_SID if the -c option is used
if [[ -n $specified_container_database ]];then
  check_container_exists_in_oratab=$(cat $ORATAB | grep -v ^'#' | grep "$specified_container_database": | awk -F: '{print $1}')
  if [[ $specified_container_database != $check_container_exists_in_oratab ]];then
    usage
    echo "The specified container database with -c doesn't exist in the oratab.  Exiting..."
    exit 1
  fi
else
  usage
  echo "The container database must be specified with -c"
  exit 1
fi

if [[ -n $retention_period_in_days_override ]];then
  if [[ ${retention_period_in_days_override} -eq ${retention_period_in_days_override} ]];then
    typeset -i retention_period_for_audit_data_in_days
    retention_period_for_audit_data_in_days=$retention_period_in_days_override
    echo "The retention period for how much SSO audit data to keep has been set to $retention_period_in_days_override days."
  else
    usage
    echo "The value specified with the -r switch is invalid."
    echo "Please specify an integer that represents a number in days for how many records to keep in the SSO audit tables."
    exit 1
  fi
else
  typeset -i retention_period_for_audit_data_in_days
  retention_period_for_audit_data_in_days=370
fi
#typeset -x retention_period_for_audit_data_in_days
export retention_period_for_audit_data_in_days

# user whose tables to prune is mandatory
if [[ -z $user_to_clean_audit_data ]];then
  usage
  echo "The -u option must be used.  Please specify the owner of the IAU_COMMON and IAU_CUSTOM tables."
  exit 1
fi
# end of validation for command line options

# FUNCTIONS
pluggable_role_check(){
role_check_for_pluggable=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << RCHKP
set feedback off heading off verify off trim on pages 0;
alter session set container=$PDB_ORACLE_SID;
select database_role from v\\$database;
RCHKP
`
return
}

sqlplus_is_present_check(){
# make sure that the sqlplus binary is found
check_for_sqlplus=$(which sqlplus)
if [[ "${check_for_sqlplus}" = "" ]]; then
  echo "The sqlplus binary can't be located."
  echo "It is either not in the PATH setting or it is not installed in the OS."
  echo "Aborting script..."
  exit 1
fi
return
}

check_for_OS_authentication () {
check_sqlplus=$($ORACLE_HOME/bin/sqlplus -S '/ as sysdba' << TSTSQL
exit;
TSTSQL
)

check_sqlplus_exit_code=$?
if [[ $check_sqlplus_exit_code != "0" ]];then
  echo "OS authentication with sqlplus is not working.  Check your value for ORACLE_SID"
  exit 1
fi
return
}

check_for_binary () {
# pass one argument to this function
# argument 1. name of OS binary

if [[ -z $1 ]];then
  echo "This function requires an argument.  Please specify the name of the binary to be checked."
  return
fi

check_for_bin=$(which $1)
if [[ "${check_for_bin}" = "" ]];then
  echo "The ${1} binary can't be located."
  echo "It is either not in the PATH setting or it is not installed in the OS."
  echo "Aborting script..."
  exit 1
fi
return
}

send_email () {
# pass ORACLE_SID or PDB_ORACLE_SID as first argument
DB_SID_VALUE=$1
# for all pluggable databases, pass a value as the 2nd argument
pdb_flag=$2

# html formatted e-mail
(
  echo "Date: $(date)"
  echo "To: $on_call_email_address"
  echo "Subject: $DB_SID_VALUE SSO Audit Data Auto cleaning report - $SSO_CLEAN_AUDIT_DATA_DATE"
  echo "MIME-Version: 1.0"
  echo 'Content-Type: text/html; charset=\"US-ASCII\"'
  echo 'Content-Transfer-Encoding: 8bit'
  echo '<html>'
  echo '<body style="background-color:black; color:LimeGreen;">'
  echo 'Content-Type: multipart/mixed; boundary="-q1w2e3r4t5"'
  echo
  echo '---q1w2e3r4t5'
  echo 'Content-Type: text/plain; charset=utf-8'
  echo 'Content-Transfer-Encoding: 8bit'
  echo "Time of report for cleaning of SSO audit data: $(date)"
  echo ""
  if [[ -z $pdb_flag ]];then
    cat $LOGDIR/${ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log | while read line
    do
      echo "${line}<br>"
    done
  else
    cat $LOGDIR/${PDB_ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log | while read line
    do
      echo "${line}<br>"
    done
  fi
  echo '</body>'
  echo '</html>'
) | sendmail $on_call_email_address

return
}

report_deferment () {
# pass ORACLE_SID or PDB_ORACLE_SID as first argument
DB_SID_VALUE=$1
# for all pluggable databases, pass a value as the 2nd argument
pdb_flag=$2

# html formatted e-mail
(
  echo "Date: $(date)"
  echo "To: $on_call_email_address"
  echo "Subject: Cleaning of SSO audit data for $DB_SID_VALUE has been deferred - $SSO_CLEAN_AUDIT_DATA_DATE"
  echo "MIME-Version: 1.0"
  echo 'Content-Type: text/html; charset=\"US-ASCII\"'
  echo 'Content-Transfer-Encoding: 8bit'
  echo '<html>'
  echo '<body style="background-color:black; color:LimeGreen;">'
  echo "Time of execution for ${0}: $(date)<br><br>"
  echo ""
  echo "The retention period of $retention_period_for_audit_data_in_days days is older than the oldest timestamp in the ${user_to_clean_audit_data}.IAU_COMMON table.<br>"
  echo "The oldest timestamp detected in the ${user_to_clean_audit_data}.IAU_COMMON table is from $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago.<br>"
  echo "The -r option will need to be used with a value that is lower than the value of $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago"
  echo "or this needs to be run at a later time, after more than $days_diff days have elapsed.<br>"
  echo '</body>'
  echo '</html>'
) | sendmail $on_call_email_address

return
}

report_cleaning_error () {
# pass ORACLE_SID or PDB_ORACLE_SID as first argument
DB_SID_VALUE=$1
# for all pluggable databases, pass a value as the 2nd argument
pdb_flag=$2

(
  echo "Date: $(date)"
  echo "To: $on_call_email_address"
  echo "Subject: $DB_SID_VALUE SSO Audit Data Auto cleaning error - $SSO_CLEAN_AUDIT_DATA_DATE"
  echo "MIME-Version: 1.0"
  echo 'Content-Type: text/html; charset=\"US-ASCII\"'
  echo 'Content-Transfer-Encoding: 8bit'
  echo '<html>'
  echo '<body style="background-color:black; color:LimeGreen;">'
  echo 'Content-Type: multipart/mixed; boundary="-q1w2e3r4t5"'
  echo
  echo '---q1w2e3r4t5'
  echo 'Content-Type: text/plain; charset=utf-8'
  echo 'Content-Transfer-Encoding: 8bit'
  echo "Time of error for cleaning of SSO audit data: $(date)"
  echo ""
  if [[ -z $pdb_flag ]];then
    cat $LOGDIR/${ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log | while read line
    do
      echo "${line}<br>"
    done
  else
    cat $LOGDIR/${PDB_ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log | while read line
    do
      echo "${line}<br>"
    done
  fi
  echo '</body>'
  echo '</html>'
) | sendmail $on_call_email_address

return
}

report_space_reclaiming_error () {
# pass ORACLE_SID or PDB_ORACLE_SID as first argument
DB_SID_VALUE=$1
# for all pluggable databases, pass a value as the 2nd argument
pdb_flag=$2

(
  echo "Date: $(date)"
  echo "To: $on_call_email_address"
  echo "Subject: $DB_SID_VALUE SSO Audit Data Auto space reclaiming error - $SSO_CLEAN_AUDIT_DATA_DATE"
  echo "MIME-Version: 1.0"
  echo 'Content-Type: text/html; charset=\"US-ASCII\"'
  echo 'Content-Transfer-Encoding: 8bit'
  echo '<html>'
  echo '<body style="background-color:black; color:LimeGreen;">'
  echo 'Content-Type: multipart/mixed; boundary="-q1w2e3r4t5"'
  echo
  echo '---q1w2e3r4t5'
  echo 'Content-Type: text/plain; charset=utf-8'
  echo 'Content-Transfer-Encoding: 8bit'
  echo "Time of error for cleaning of SSO audit data: $(date)"
  echo ""
  if [[ -z $pdb_flag ]];then
    cat $LOGDIR/${ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log | while read line
    do
      echo "${line}<br>"
    done
  else
    cat $LOGDIR/${PDB_ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log | while read line
    do
      echo "${line}<br>"
    done
  fi
  echo '</body>'
  echo '</html>'
) | sendmail $on_call_email_address

return
}

# 2 main functions; 1 for non-CDB architecture, 1 for CDB/PDB architecture
# check_non_pdb_cdb
# pdb_cdb_check

check_non_pdb_cdb () {
sqlplus_is_present_check
check_for_OS_authentication

user_to_clean_audit_data=$1
retention_period_for_audit_data_in_days=$2

# check traditional single instance oracle database here

# validate user from -u command line option
typeset -i SPECIFIED_USER_COUNT
SPECIFIED_USER_COUNT=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << USERCNT
set feedback off heading off verify off pages 0 trim on;
whenever sqlerror exit 1;
select count(*) from DBA_USERS
WHERE USERNAME = '$user_to_clean_audit_data';
USERCNT
`
echo "SPECIFIED_USER_COUNT: $SPECIFIED_USER_COUNT - $user_to_clean_audit_data user exists in database.  Check passed."

# check for tables that need to be cleaned under the indicated user/schema
typeset -i USER_IAU_COMMON_COUNT
USER_IAU_COMMON_COUNT=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << USRIAUCO
set feedback off heading off verify off pages 0 trim on;
whenever sqlerror exit 1;
select count(*) from DBA_TABLES
WHERE OWNER = '$user_to_clean_audit_data'
and TABLE_NAME = 'IAU_COMMON';
USRIAUCO
`
USER_IAU_COMMON_COUNT_EXIT_CODE=$?

typeset -i USER_IAU_CUSTOM_COUNT
USER_IAU_CUSTOM_COUNT=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << USRIAUCU
set feedback off heading off verify off pages 0 trim on;
whenever sqlerror exit 1;
select count(*) from DBA_TABLES
WHERE OWNER = '$user_to_clean_audit_data'
and TABLE_NAME = 'IAU_CUSTOM';
USRIAUCU
`
USER_IAU_CUSTOM_COUNT_EXIT_CODE=$?

if (( $SPECIFIED_USER_COUNT < 1 ));then
  echo "Something went wrong while checking for the specified user with the -u option."
  echo "The $user_to_clean_audit_data database user might not exist."
  exit 1
else
  echo "The specified user with the -u command line option seems to exist.  Check passed."
fi

if [[ $USER_IAU_COMMON_COUNT_EXIT_CODE != "0" ]] || [[ -z $USER_IAU_COMMON_COUNT ]];then
  echo "Something went wrong while checking for the existence of the ${user_to_clean_audit_data}.IAU_COMMON table."
  echo "The ${user_to_clean_audit_data}.IAU_COMMON table might not exist."
  exit 1
else
  echo "The ${user_to_clean_audit_data}.IAU_COMMON table seems to exist."
fi

if [[ $USER_IAU_CUSTOM_COUNT_EXIT_CODE != "0" ]] || [[ -z $USER_IAU_CUSTOM_COUNT ]];then
  echo "Something went wrong while checking for the existence of the ${user_to_clean_audit_data}.IAU_CUSTOM table."
  echo "The ${user_to_clean_audit_data}.IAU_CUSTOM table might not exist."
  exit 1
else
  echo "The ${user_to_clean_audit_data}.IAU_CUSTOM table seems to exist."
fi

echo "Cleaning SSO audit data in ${ORACLE_SID} database..."

# get oldest timestamp on IAU_COMMON
# for iterative cleaning because this will be one of the largest tables
typeset -i OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << OLDDAYS
set feedback off heading off verify off pages 0 trim on;
alter session set current_schema=${user_to_clean_audit_data};
select trunc(sysdate) - trunc(min(IAU_TstzOriginating)) from ${user_to_clean_audit_data}.IAU_COMMON;
OLDDAYS
`

echo "The oldest timestamp found in the IAU_TstzOriginating column in the ${user_to_clean_audit_data}.IAU_COMMON table is from $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."

# iterated cleaning based on value of OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
# done this way, in a decrementing fashion, to reduce the amount of undo generated, so it doesn't balloon the UNDO tablespace
if (( $retention_period_for_audit_data_in_days <= $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE ));then

  # loop cleaning until the $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE reaches the value of the retention_period_for_audit_data_in_days_baseline
  while (( $retention_period_for_audit_data_in_days <= $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE ));do

# prune audit tables based on retention
# pass in 2 values
# 1. the correct schema name that has the tables that need to be pruned
# 2. the value of the retention of audit data, a number in days
$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << CLNAUD
spool $LOGDIR/${ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log;
ALTER SESSION SET CURRENT_SCHEMA=$user_to_clean_audit_data;
whenever sqlerror exit 1;
ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-YYYY HH24:MI:SS';

delete from IAU_BASE where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from AdminServer where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from DIP where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from JPS where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OAAM where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OAM where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OIF where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OVD where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OHSComponent where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OIDComponent where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from WebCacheComponent where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from OWSM_PM_EJB where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from OWSM_AGENT where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from WS_PolicyAttachment where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from WebServices where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from STS where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from SOA_B2B where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from SOA_HCFP where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from XMLPSERVER where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);

--custom tables
delete from IAU_CUSTOM where IAU_ID in (select IAU_ID from IAU_COMMON where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE)); 

DECLARE
    l_count   NUMBER;
    my_sql    VARCHAR (200);
BEGIN
    SELECT COUNT (*)
      INTO l_count
      FROM IAU_COMMON
     where IAU_TstzOriginating < ( systimestamp - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);

    IF( l_count > 0 )
    THEN
        FOR t
            IN (SELECT  t.table_name, t.owner
                  FROM  all_tables t
                 where upper(owner) = upper('$user_to_clean_audit_data')
                   AND table_name LIKE 'IAU_CUSTOM_%')
        LOOP
            my_sql := 
                   'delete from '
                || t.owner
                || '.'
                || t.table_name
                || ' where IAU_ID in (select IAU_ID from '
                || t.owner
                || '.IAU_COMMON where IAU_TstzOriginating < (systimestamp - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE))';
                
            EXECUTE IMMEDIATE my_sql;
        END LOOP;
    END IF;
EXCEPTION
    WHEN OTHERS
    THEN
        DBMS_OUTPUT.put_line ('ERROR!! -- ' || SQLCODE || '--' || SQLERRM);
END;
/

-- common table
delete from IAU_COMMON where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
 
commit;
spool off;
CLNAUD

clean_audit_data_exit_code=$?

# decrement counter for OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
#OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE=$OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE-1
(( OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE -= 1 ))

# $retention_period_for_audit_data_in_days < $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
done

# only check exit code after last iteration
if [[ $clean_audit_data_exit_code != "0" ]];then
  if [[ $disable_email_alerting != "1" ]];then
    echo "Error detected for the cleaning of SSO audit data in ${ORACLE_SID} database."
    report_cleaning_error $ORACLE_SID
  else
    echo "Error detected for the cleaning of SSO audit data in ${ORACLE_SID} database."
  fi
fi

# enable row movement and shrink tables in order to conserve tablespace usage
# no loop on this; only done once
$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << SHRNKAUD
spool $LOGDIR/${ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log append;
ALTER SESSION SET CURRENT_SCHEMA=$user_to_clean_audit_data;
whenever sqlerror exit 1;

-- row movement
ALTER TABLE IAU_BASE enable row movement;
ALTER TABLE AdminServer enable row movement;
ALTER TABLE DIP enable row movement;
ALTER TABLE JPS enable row movement;
ALTER TABLE OAAM enable row movement;
ALTER TABLE OAM enable row movement;
ALTER TABLE OIF enable row movement;
ALTER TABLE OVD enable row movement;
ALTER TABLE OHSComponent enable row movement;
ALTER TABLE OIDComponent enable row movement;
ALTER TABLE WebCacheComponent enable row movement;
ALTER TABLE OWSM_PM_EJB enable row movement;
ALTER TABLE OWSM_AGENT enable row movement;
ALTER TABLE WS_PolicyAttachment enable row movement;
ALTER TABLE WebServices enable row movement;
ALTER TABLE STS enable row movement;
ALTER TABLE SOA_B2B enable row movement;
ALTER TABLE SOA_HCFP enable row movement;
ALTER TABLE XMLPSERVER enable row movement;
ALTER TABLE IAU_COMMON enable row movement;
ALTER TABLE IAU_CUSTOM enable row movement;

-- shrink space
ALTER TABLE IAU_BASE SHRINK SPACE CASCADE;
ALTER TABLE AdminServer SHRINK SPACE CASCADE;
ALTER TABLE DIP SHRINK SPACE CASCADE;
ALTER TABLE JPS SHRINK SPACE CASCADE;
ALTER TABLE OAAM SHRINK SPACE CASCADE;
ALTER TABLE OAM SHRINK SPACE CASCADE;
ALTER TABLE OIF SHRINK SPACE CASCADE;
ALTER TABLE OVD SHRINK SPACE CASCADE;
ALTER TABLE OHSComponent SHRINK SPACE CASCADE;
ALTER TABLE OIDComponent SHRINK SPACE CASCADE;
ALTER TABLE WebCacheComponent SHRINK SPACE CASCADE;
ALTER TABLE OWSM_PM_EJB SHRINK SPACE CASCADE;
ALTER TABLE OWSM_AGENT SHRINK SPACE CASCADE;
ALTER TABLE WS_PolicyAttachment SHRINK SPACE CASCADE;
ALTER TABLE WebServices SHRINK SPACE CASCADE;
ALTER TABLE STS SHRINK SPACE CASCADE;
ALTER TABLE SOA_B2B SHRINK SPACE CASCADE;
ALTER TABLE SOA_HCFP SHRINK SPACE CASCADE;
ALTER TABLE XMLPSERVER SHRINK SPACE CASCADE;
ALTER TABLE IAU_COMMON SHRINK SPACE CASCADE;
ALTER TABLE IAU_CUSTOM SHRINK SPACE CASCADE;

--custom tables
DECLARE
        row_sql varchar(100);
        shrink_sql varchar(100);
BEGIN

    FOR t IN (SELECT  t.table_name, t.owner FROM  all_tables t where upper(owner) = upper('$user_to_clean_audit_data') AND table_name LIKE 'IAU_CUSTOM_%')
    LOOP
       row_sql := 'ALTER TABLE ' || t.table_name || ' enable row movement';
       EXECUTE IMMEDIATE row_sql;
       shrink_sql := 'ALTER TABLE ' || t.table_name || ' shrink space cascade';
       EXECUTE IMMEDIATE shrink_sql;
    END LOOP;
EXCEPTION
        WHEN OTHERS THEN
        dbms_output.put_line('ERROR!! -- '  || SQLCODE || '--' || sqlerrm );
END;
/

commit;
spool off;
SHRNKAUD

reclaim_audit_data_exit_code=$?
# only check exit code on last iteration
if [[ $reclaim_audit_data_exit_code != "0" ]];then
  if [[ $disable_email_alerting != "1" ]];then
    echo "Error detected for the reclaiming of SSO audit data in ${ORACLE_SID} database."
    report_space_reclaiming_error $ORACLE_SID
  else
    echo "Error detected for the reclaiming of SSO audit data in ${ORACLE_SID} database."
  fi
fi


if [[ $disable_email_alerting != "1" ]];then
  send_email $ORACLE_SID
else
  echo "The results of this report can be found at $LOGDIR/${ORACLE_SID}_daily_SSO_audit_data_cleaning.log"
  # cat $LOGDIR/${ORACLE_SID}_daily_SSO_audit_data_cleaning.log
fi

else
  typeset -i days_diff
  days_diff=$(( $retention_period_for_audit_data_in_days - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE ))
  usage
  if [[ $disable_email_alerting != "1" ]];then
    echo "The retention period of $retention_period_for_audit_data_in_days days is older than the oldest timestamp in the ${user_to_clean_audit_data}.IAU_COMMON table."
    echo "The oldest timestamp detected in the ${user_to_clean_audit_data}.IAU_COMMON table is from $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "The -r option will need to be used with a value that is lower than the value of $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "or this needs to be run at a later time, after more than $days_diff days have elapsed."
    report_deferment $ORACLE_SID
  else
    echo "The retention period of $retention_period_for_audit_data_in_days days is older than the oldest timestamp in the ${user_to_clean_audit_data}.IAU_COMMON table."
    echo "The oldest timestamp detected in the ${user_to_clean_audit_data}.IAU_COMMON table is from $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "The -r option will need to be used with a value that is lower than the value of $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "or this needs to be run at a later time, after more than $days_diff days have elapsed."
  fi
  exit 1
# $retention_period_for_audit_data_in_days < $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
fi

find $LOGDIR -name *_daily_SSO_audit_data_cleaning.log -mtime +$LOG_DIR_RETENTION_IN_DAYS -exec rm {} \;

return
# check_non_pdb_cdb
}

pdb_cdb_check () {
# use the first argument to this function as the value for the PDB
PDB_ORACLE_SID=$1
user_to_clean_audit_data=$2
retention_period_for_audit_data_in_days=$3

sqlplus_is_present_check
check_for_OS_authentication

PDB_OPEN_CHECK=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << PDBOPCHK
set feedback off heading off verify off trim on pages 0;
alter session set container=$PDB_ORACLE_SID;
select status from v\$instance;
PDBOPCHK
)

PDB_STATE_CHECK=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << PDBRWCHK
set feedback off heading off verify off trim on pages 0;
alter session set container=$PDB_ORACLE_SID;
select open_mode from v\\$pdbs where name = '${PDB_ORACLE_SID}';
PDBRWCHK
`

if [[ $PDB_OPEN_CHECK = "OPEN" || $PDB_OPEN_CHECK = "MOUNTED" ]] && [[ $PDB_STATE_CHECK = "MOUNTED" || $PDB_STATE_CHECK = "READ WRITE" || $PDB_STATE_CHECK = "READ ONLY" ]];then
  # role check for pluggable
  pluggable_role_check
  if [[ $role_check_for_pluggable = 'PHYSICAL STANDBY' ]];then
    usage
    echo "The $specified_pluggable_database database is a PHYSICAL STANDBY and won't have any SSO related audit data reduced."
    exit 1
  fi

# validate user from -u command line option
typeset -i SPECIFIED_USER_COUNT
SPECIFIED_USER_COUNT=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << USERCNT
set feedback off heading off verify off pages 0 trim on;
whenever sqlerror exit 1;
alter session set container=$PDB_ORACLE_SID;
select count(*) from DBA_USERS
WHERE USERNAME = '$user_to_clean_audit_data';
USERCNT
`
echo "SPECIFIED_USER_COUNT: $SPECIFIED_USER_COUNT - $user_to_clean_audit_data user exists in database.  Check passed."

# check for tables that need to be cleaned under the indicated user/schema
typeset -i USER_IAU_COMMON_COUNT
USER_IAU_COMMON_COUNT=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << USRIAUCO
set feedback off heading off verify off pages 0 trim on;
whenever sqlerror exit 1;
alter session set container=$PDB_ORACLE_SID;
select count(*) from DBA_TABLES
WHERE OWNER = '$user_to_clean_audit_data'
and TABLE_NAME = 'IAU_COMMON';
USRIAUCO
`
USER_IAU_COMMON_COUNT_EXIT_CODE=$?

typeset -i USER_IAU_CUSTOM_COUNT
USER_IAU_CUSTOM_COUNT=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << USRIAUCU
set feedback off heading off verify off pages 0 trim on;
whenever sqlerror exit 1;
alter session set container=$PDB_ORACLE_SID;
select count(*) from DBA_TABLES
WHERE OWNER = '$user_to_clean_audit_data'
and TABLE_NAME = 'IAU_CUSTOM';
USRIAUCU
`
USER_IAU_CUSTOM_COUNT_EXIT_CODE=$?

if (( $SPECIFIED_USER_COUNT < 1 ));then
  echo "Something went wrong while checking for the specified user with the -u option."
  echo "The $user_to_clean_audit_data database user might not exist."
  exit 1
else
  echo "The specified user with the -u command line option seems to exist.  Check passed."
fi

if [[ $USER_IAU_COMMON_COUNT_EXIT_CODE != "0" ]] || [[ -z $USER_IAU_COMMON_COUNT ]];then
  echo "Something went wrong while checking for the existence of the ${user_to_clean_audit_data}.IAU_COMMON table."
  echo "The ${user_to_clean_audit_data}.IAU_COMMON table might not exist."
  exit 1
else
  echo "The ${user_to_clean_audit_data}.IAU_COMMON table seems to exist."
fi

if [[ $USER_IAU_CUSTOM_COUNT_EXIT_CODE != "0" ]] || [[ -z $USER_IAU_CUSTOM_COUNT ]];then
  echo "Something went wrong while checking for the existence of the ${user_to_clean_audit_data}.IAU_CUSTOM table."
  echo "The ${user_to_clean_audit_data}.IAU_CUSTOM table might not exist."
  exit 1
else
  echo "The ${user_to_clean_audit_data}.IAU_CUSTOM table seems to exist."
fi

echo "Cleaning SSO audit data in ${PDB_ORACLE_SID} database..."

# get oldest timestamp on IAU_COMMON
# for iterative cleaning because this will be one of the largest tables
typeset -i OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << OLDDAYS
set feedback off heading off verify off pages 0 trim on;
alter session set container=$PDB_ORACLE_SID;
alter session set current_schema=${user_to_clean_audit_data};
select trunc(sysdate) - trunc(min(IAU_TstzOriginating)) from ${user_to_clean_audit_data}.IAU_COMMON;
OLDDAYS
`

echo "The oldest timestamp found in the IAU_TstzOriginating column in the ${user_to_clean_audit_data}.IAU_COMMON table is from $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."

# iterated cleaning based on value of OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
# done this way, in a decrementing fashion, to reduce the amount of undo generated, so it doesn't balloon the UNDO tablespace
if (( $retention_period_for_audit_data_in_days <= $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE ));then

  # loop cleaning until the $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE reaches the value of the retention_period_for_audit_data_in_days_baseline
  while (( $retention_period_for_audit_data_in_days <= $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE ));do

# prune audit tables based on retention
# pass in 2 values
# 1. the correct schema name that has the tables that need to be pruned
# 2. the value of the retention of data, a number in days
$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << CLNAUD
spool $LOGDIR/${PDB_ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log;
alter session set container=$PDB_ORACLE_SID;
ALTER SESSION SET CURRENT_SCHEMA=$user_to_clean_audit_data;
whenever sqlerror exit 1;
ALTER SESSION SET NLS_DATE_FORMAT = 'DD-MON-YYYY HH24:MI:SS';

delete from IAU_BASE where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from AdminServer where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from DIP where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from JPS where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OAAM where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OAM where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OIF where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OVD where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OHSComponent where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from OIDComponent where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 
delete from WebCacheComponent where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from OWSM_PM_EJB where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from OWSM_AGENT where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from WS_PolicyAttachment where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from WebServices where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from STS where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from SOA_B2B where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from SOA_HCFP where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);
delete from XMLPSERVER where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);

--custom tables
delete from IAU_CUSTOM where IAU_ID in (select IAU_ID from IAU_COMMON where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE)); 

DECLARE
    l_count   NUMBER;
    my_sql    VARCHAR (200);
BEGIN
    SELECT COUNT (*)
      INTO l_count
      FROM IAU_COMMON
     where IAU_TstzOriginating < ( systimestamp - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE);

    IF( l_count > 0 )
    THEN
        FOR t
            IN (SELECT  t.table_name, t.owner
                  FROM  all_tables t
                 where upper(owner) = upper('$user_to_clean_audit_data')
                   AND table_name LIKE 'IAU_CUSTOM_%')
        LOOP
            my_sql := 
                   'delete from '
                || t.owner
                || '.'
                || t.table_name
                || ' where IAU_ID in (select IAU_ID from '
                || t.owner
                || '.IAU_COMMON where IAU_TstzOriginating < (systimestamp - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE))';
                
            EXECUTE IMMEDIATE my_sql;
        END LOOP;
    END IF;
EXCEPTION
    WHEN OTHERS
    THEN
        DBMS_OUTPUT.put_line ('ERROR!! -- ' || SQLCODE || '--' || SQLERRM);
END;
/

-- common table
delete from IAU_COMMON where IAU_TstzOriginating < (systimestamp  - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE); 

commit;
spool off;
CLNAUD

clean_audit_data_exit_code=$?

# decrement counter for OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
#OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE=$OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE-1
(( OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE -= 1 ))

# $retention_period_for_audit_data_in_days < $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
done

# only check exit code after last iteration
if [[ $clean_audit_data_exit_code != "0" ]];then
  if [[ $disable_email_alerting != "1" ]];then
    echo "Error detected for the cleaning of SSO audit data in ${PDB_ORACLE_SID} database."
    report_cleaning_error $PDB_ORACLE_SID
  else
    echo "Error detected for the cleaning of SSO audit data in ${PDB_ORACLE_SID} database."
  fi
fi

# enable row movement and shrink tables in order to conserve tablespace usage
$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << SHRNKAUD
spool $LOGDIR/${PDB_ORACLE_SID}_${SSO_CLEAN_AUDIT_DATA_DATE_UNDERSCORES}_daily_SSO_audit_data_cleaning.log append;
alter session set container=$PDB_ORACLE_SID;
ALTER SESSION SET CURRENT_SCHEMA=$user_to_clean_audit_data;
whenever sqlerror exit 1;

-- row movement
ALTER TABLE IAU_BASE enable row movement;
ALTER TABLE AdminServer enable row movement;
ALTER TABLE DIP enable row movement;
ALTER TABLE JPS enable row movement;
ALTER TABLE OAAM enable row movement;
ALTER TABLE OAM enable row movement;
ALTER TABLE OIF enable row movement;
ALTER TABLE OVD enable row movement;
ALTER TABLE OHSComponent enable row movement;
ALTER TABLE OIDComponent enable row movement;
ALTER TABLE WebCacheComponent enable row movement;
ALTER TABLE OWSM_PM_EJB enable row movement;
ALTER TABLE OWSM_AGENT enable row movement;
ALTER TABLE WS_PolicyAttachment enable row movement;
ALTER TABLE WebServices enable row movement;
ALTER TABLE STS enable row movement;
ALTER TABLE SOA_B2B enable row movement;
ALTER TABLE SOA_HCFP enable row movement;
ALTER TABLE XMLPSERVER enable row movement;
ALTER TABLE IAU_COMMON enable row movement;
ALTER TABLE IAU_CUSTOM enable row movement;

-- shrink space
ALTER TABLE IAU_BASE SHRINK SPACE CASCADE;
ALTER TABLE AdminServer SHRINK SPACE CASCADE;
ALTER TABLE DIP SHRINK SPACE CASCADE;
ALTER TABLE JPS SHRINK SPACE CASCADE;
ALTER TABLE OAAM SHRINK SPACE CASCADE;
ALTER TABLE OAM SHRINK SPACE CASCADE;
ALTER TABLE OIF SHRINK SPACE CASCADE;
ALTER TABLE OVD SHRINK SPACE CASCADE;
ALTER TABLE OHSComponent SHRINK SPACE CASCADE;
ALTER TABLE OIDComponent SHRINK SPACE CASCADE;
ALTER TABLE WebCacheComponent SHRINK SPACE CASCADE;
ALTER TABLE OWSM_PM_EJB SHRINK SPACE CASCADE;
ALTER TABLE OWSM_AGENT SHRINK SPACE CASCADE;
ALTER TABLE WS_PolicyAttachment SHRINK SPACE CASCADE;
ALTER TABLE WebServices SHRINK SPACE CASCADE;
ALTER TABLE STS SHRINK SPACE CASCADE;
ALTER TABLE SOA_B2B SHRINK SPACE CASCADE;
ALTER TABLE SOA_HCFP SHRINK SPACE CASCADE;
ALTER TABLE XMLPSERVER SHRINK SPACE CASCADE;
ALTER TABLE IAU_COMMON SHRINK SPACE CASCADE;
ALTER TABLE IAU_CUSTOM SHRINK SPACE CASCADE;

--custom tables
DECLARE
        row_sql varchar(100);
        shrink_sql varchar(100);
BEGIN

    FOR t IN (SELECT  t.table_name, t.owner FROM  all_tables t where upper(owner) = upper('$user_to_clean_audit_data') AND table_name LIKE 'IAU_CUSTOM_%')
    LOOP
       row_sql := 'ALTER TABLE ' || t.table_name || ' enable row movement';
       EXECUTE IMMEDIATE row_sql;
       shrink_sql := 'ALTER TABLE ' || t.table_name || ' shrink space cascade';
       EXECUTE IMMEDIATE shrink_sql;
    END LOOP;
EXCEPTION
        WHEN OTHERS THEN
        dbms_output.put_line('ERROR!! -- '  || SQLCODE || '--' || sqlerrm );
END;
/

commit;
spool off;
SHRNKAUD

reclaim_audit_data_exit_code=$?
# only check exit code on last iteration
if [[ $reclaim_audit_data_exit_code != "0" ]];then
  if [[ $disable_email_alerting != "1" ]];then
    echo "Error detected for the reclaiming of SSO audit data in ${PDB_ORACLE_SID} database."
    report_deferment $PDB_ORACLE_SID
  else
    echo "Error detected for the reclaiming of SSO audit data in ${PDB_ORACLE_SID} database."
  fi
fi

if [[ $disable_email_alerting != "1" ]];then
  send_email $PDB_ORACLE_SID PDB
else
  echo "The results of this report can be found at $LOGDIR/${PDB_ORACLE_SID}_daily_SSO_audit_data_cleaning.log"
  # cat $LOGDIR/${PDB_ORACLE_SID}_daily_SSO_audit_data_cleaning.log
fi

else
  typeset -i days_diff
  days_diff=$(( $retention_period_for_audit_data_in_days - $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE ))
  usage
  if [[ $disable_email_alerting != "1" ]];then
    echo "The retention period of $retention_period_for_audit_data_in_days days is older than the oldest timestamp in the ${user_to_clean_audit_data}.IAU_COMMON table."
    echo "The oldest timestamp detected in the ${user_to_clean_audit_data}.IAU_COMMON table is from $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "The -r option will need to be used with a value that is lower than the value of $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "or this needs to be run at a later time, after more than $days_diff days have elapsed."
    report_deferment $PDB_ORACLE_SID
  else
    echo "The retention period of $retention_period_for_audit_data_in_days days is older than the oldest timestamp in the ${user_to_clean_audit_data}.IAU_COMMON table."
    echo "The oldest timestamp detected in the ${user_to_clean_audit_data}.IAU_COMMON table is from $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "The -r option will need to be used with a value that is lower than the value of $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE days ago."
    echo "or this needs to be run at a later time, after more than $days_diff days have elapsed."
  fi
  exit 1
# $retention_period_for_audit_data_in_days < $OLDEST_TIMESTAMP_IN_NUMBER_OF_DAYS_FROM_SYSDATE
fi

find $LOGDIR -name *_daily_SSO_audit_data_cleaning.log -mtime +$LOG_DIR_RETENTION_IN_DAYS -exec rm {} \;

else
  echo "The $PDB_ORACLE_SID database isn't in an OPEN or MOUNTED state."
  echo "The database is in $PDB_OPEN_CHECK when checking v\$instance"
  echo "The database is in $PDB_STATE_CHECK when checking v\$pdbs"
  echo "Skipping this database..."
# DATABASE_OPEN_CHECK OPEN or MOUNTED
fi

return
# pdb_cdb_check
}

check_specified_container_present_in_running_processes(){
for SID_to_check in ${ORACLE_SID_LIST[@]}
do
  if [[ ${specified_container_database} = ${SID_to_check} ]];then
    echo "The specified container database with -c was found as a running process."
    specified_container_database_found="TRUE"
    break
  fi
done

if [[ $specified_container_database_found != "TRUE" ]];then
  usage
  echo "The specified container database with -c wasn't found as a running process.  Exiting..."
  exit 1
fi
}

database_open_check(){
# check for open database before any other checks execute
# bad things happen if this isn't done as the first check
DATABASE_OPEN_CHECK=$($ORACLE_HOME/bin/sqlplus -S '/ as sysdba' << EOS
set heading off feedback off linesize 150 trim on pages 0;
select status from v\$instance;
exit;
EOS
)
return
}

database_role_check(){
DATABASE_ROLE_CHECK=$($ORACLE_HOME/bin/sqlplus -S '/ as sysdba' << EOS
set heading off feedback off linesize 150 trim on pages 0;
select database_role from v\$database;
exit;
EOS
)
return
}

# check for retention_period_for_audit_data_in_days variable
check_for_retention_period_for_audit_data_in_days_variable(){
if [[ -z $retention_period_for_audit_data_in_days ]];then
  echo "The retention_period_for_audit_data_in_days variable isn't populated."
  echo "Something has gone wrong.  Contact the developer for assistance."
  exit 1
fi
}
# END OF FUNCTIONS


# START MAIN HERE

if [[ -n $specified_container_database ]] && [[ -n $specified_pluggable_database ]]; then
  echo "Command line settings for a pluggable database have been specified."
  echo "Checking specified container and pluggable database."
  # check for container database in running processes
  check_specified_container_present_in_running_processes
  set_environment $specified_container_database
  check_for_retention_period_for_audit_data_in_days_variable
  check_for_binary awk
  check_for_binary cut
  check_for_binary date
  check_for_binary grep
  check_for_binary mailx
  check_for_binary ps
  check_for_binary sed
  check_for_binary sendmail
  check_for_binary whoami
  sqlplus_is_present_check
  check_for_OS_authentication
  database_open_check

  if [[ ${DATABASE_OPEN_CHECK} = "OPEN" ]] || [[ ${DATABASE_OPEN_CHECK} = "MOUNTED" ]]; then
    database_role_check
    if [[ ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY" ]]; then
      usage
      echo "The $ORACLE_SID database is a PHYSICAL STANDBY and won't have any audit data cleaned."
      exit 1
    fi
  else
    usage
    echo "The $ORACLE_SID database isn't in an OPEN state."
    echo "Exiting..."
    exit 1
  fi

# check to see if pluggable database is being used
# value will be YES if a pdb is used
# value will be NO if it is a regular database
PDB_DATABASE_CHECK=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << PDBCHK
set feedback off heading off verify off trim on pages 0;
select CDB from v\\$database;
PDBCHK
`

specified_pdb_check=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << LISTPDB
set feedback off heading off verify off trim on pages 0;
select name from v\\$pdbs where name = '\$specified_pluggable_database';
LISTPDB
`

  if [[ $PDB_DATABASE_CHECK = "YES" ]]; then
    echo "Container/pluggable database architecture detected.";sleep 1
    if [[ $specified_pdb_check != $specified_pluggable_database ]];then
      usage
      echo "The specified pluggable database is invalid.  It is not a database within the $specified_container_database container database."
      exit 1
    fi
  else
    usage
    echo "You have specified a pluggable database, but this database is traditional single instance."
    exit 1
  fi

  echo "Checking pluggable database: $specified_pluggable_database"
  pdb_cdb_check $specified_pluggable_database $user_to_clean_audit_data $retention_period_for_audit_data_in_days

# -n $specified_container_database -n $specified_pluggable_database
else
  if [[ -n $specified_container_database ]] && [[ -z $specified_pluggable_database ]];then
    echo "Checking specified single instance/container database."
    # check for container database in running processes
    check_specified_container_present_in_running_processes
    set_environment $specified_container_database
    check_for_retention_period_for_audit_data_in_days_variable
    check_for_binary awk
    check_for_binary cut
    check_for_binary date
    check_for_binary grep
    check_for_binary mailx
    check_for_binary ps
    check_for_binary sed
    check_for_binary sendmail
    check_for_binary whoami
    sqlplus_is_present_check
    check_for_OS_authentication
    database_open_check

    if [[ ${DATABASE_OPEN_CHECK} = "OPEN" ]] || [[ ${DATABASE_OPEN_CHECK} = "MOUNTED" ]]; then
      database_role_check
      if [[ ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY" ]]; then
        usage
        echo "The $ORACLE_SID database is a PHYSICAL STANDBY and won't have any SSO related audit data reduced."
        exit 1
      else
        # echo "Checking container or single instance database."
        check_non_pdb_cdb $user_to_clean_audit_data $retention_period_for_audit_data_in_days
      fi
    else
      usage
      echo "The $ORACLE_SID database isn't in an OPEN state."
      exit 1
    fi

  # -n $specified_container_database && -z $specified_pluggable_database
  fi

# -n $specified_container_database && -n $specified_pluggable_database
fi

exit 0
