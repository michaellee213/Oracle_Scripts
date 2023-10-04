#!/usr/bin/ksh
#
# Title:        check_for_datapatch_execution.ksh
# Purpose:      Execute this after Oracle Database patching to make sure that datapatch -verbose was executed.
#                
# Usage:        check_for_datapatch_execution.ksh
#               example crontab: 1 0 * * 0-6 /opt/oracle/admin/scripts/check_for_datapatch_execution.ksh > /var/opt/oracle/log/check_for_datapatch_execution.log 2>&1
#
# Author:       Michael Lee
# Created on:   3OCT2023
#
# Notes:        This script is for use on any Oracle database server in order to make sure that "datapatch -verbose" has been executed after DB home/ORACLE_HOME patching has occurred.
#               If desired, you can automatically run "datapatch -verbose" in case you have forgetful DBAs who don't run this after patching an ORACLE_HOME.
#
# Revisions:    Date       UID             Description
#               ---------- --------------- ------------------------------------------------------------
#               3OCT2023   michaellee      first draft
#
# Runtime:      TBD
# Size:         This script doesn't produce any file so size is not applicable.
#

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin:/usr/ucb
host=$(hostname)
ostype=$(uname)

# uncomment to enable debug mode
#set -x

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

check_for_binary () {
# pass one argument to this function
# argument 1. name of OS binary

if [[ -z $1 ]];then
  echo "This function requires an argument.  Please specify the name of the binary to be checked."
  return
fi

check_for_bin=$(which $1 2>/dev/null)
if [[ ! -f "${check_for_bin}" ]];then
  echo "The ${1} binary can't be located."
  echo "It is either not in the PATH setting or it is not installed in the OS."
  echo "Aborting script..."
  exit 1
fi
return
}

usage () {
  echo "This script will check the database server(s) after patching has occurred."
  echo "${0} is a health check that can be run at any time, but is mostly for after OS patching has occurred."
  echo "This will check that \"datapatch -verbose\" has been executed after \"opatch apply\" has been executed."
  echo ""
  echo "Usage: ${0} <options>"
  echo ""
  echo " -p, --pdbs           OPTIONAL: check all PDBs for the correct data in the dba_registry_sqlpatch view"
  echo ""
  echo " -c, --correct        OPTIONAL: this will automatically run \"datapatch -verbose\" for the database if used"
  echo ""
  echo " -e                   OPTIONAL: this will enable e-mail alerts"
  echo "                                and can be used on the command line."
  echo "                                for testing before this script is deployed as a scheduled job."
  echo ""
  echo " -h, --help           OPTIONAL: this help menu"
  echo ""
}

while getopts "c(correct)eh(help)p(pdbs)" options;do
  case $options in
  c ) correct_datapatch_boolean=1;; # auto correct situation by auto executing "datapatch -verbose"
  e ) enable_email_alerting=1 ;; #e-mail alerting always off by default; this enables it
  p ) check_pdbs_boolean=1;; #check all PDBs for the expected data in the dba_registry_sqlpatch view
  h ) usage; exit 0;;
  * ) echo "Unimplemented option. -$OPTARG" >&2; usage; exit 1;;
  esac
done

# validate command line options
if [[ $enable_email_alerting = "1" ]];then
  echo "The -e option has been used.  E-mail alerts have been enabled."
fi
if [[ -n $check_pdbs_boolean ]];then
  echo "The -p or --pdbs option has been used.  All PDBs will be checked for up to date patching data in the dba_registry_sqlpatch view."
fi
# end of validate command line options

# build array of all ORACLE_SID values; will be used for all conditions, command line options present or not
ps -ef | grep ora_pmon | grep -v 'grep' | grep 'oracle' | awk '{print $NF}' | sed 's-ora_pmon_--' | grep -v 's---' | { \
  oracle_sid_list_index=0;
  set -A ORACLE_SID_LIST
  while read ORACLE_SID_LIST_PROCESSES
  do
    ORACLE_SID_LIST[$oracle_sid_list_index]=$ORACLE_SID_LIST_PROCESSES
    let oracle_sid_list_index=$oracle_sid_list_index+1
  done;
}

# FUNCTIONS
clean_environment () {
# unset all default environment variables
env | grep -v ^'HOME' | grep -v 'eval' | grep -v ^'BASH_FUNC' | grep -v ^'\}' | awk -F'=' '{print $1}' | grep -v 'enable_email_alerting' | grep -v 'correct_datapatch_boolean' | grep -v 'check_pdbs_boolean' | while read var
do
  unset $var
done
unset TWO_TASK
# Do not error on unset environment variables during substitution
set +u
return
}

set_environment () {
clean_environment
on_call_email_address=""
PATH=/usr/bin:/bin:/usr/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin
export PATH
TODAY=$(date "+%d%b%Y")
TODAY_WITH_SECONDS=$(date "+%d%b%Y_%H%M%S")
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
#. oraenv
export ORACLE_HOME
LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib:/lib
export PATH LD_LIBRARY_PATH
if [[ -n $ORACLE_BASE_override ]];then
  ORACLE_BASE=$ORACLE_BASE_override
fi
# remove trailing slash
ORACLE_BASE=${ORACLE_BASE%/}
export ORACLE_BASE
TMP=/tmp;TEMP=/tmp;TMPDIR=/tmp
export TMP TEMP TMPDIR
check_for_binary date

host=$(hostname)
HOST=$(hostname | awk -F. '{print $1}')
export host HOST

return
}

# FUNCTIONS

database_role_check(){
DATABASE_ROLE_CHECK=$($ORACLE_HOME/bin/sqlplus -S '/ as sysdba' << EOS
set heading off feedback off linesize 150 trim on pages 0;
select database_role from v\$database;
exit;
EOS
)

export DATABASE_ROLE_CHECK
}

pluggable_role_check(){
PDB_FOR_QUERY=$1
role_check_for_pluggable=`$ORACLE_HOME/bin/sqlplus -S "/ as sysdba" << RCHKP
set feedback off heading off verify off trim on pages 0;
alter session set container=$PDB_FOR_QUERY;
select database_role from v\\$database;
RCHKP
`
export role_check_for_pluggable
}

cdb_pdb_check(){
# check to see if pluggable database is being used
# value will be YES if a pdb is used
# value will be NO if it is a regular database
PDB_DATABASE_CHECK=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << PDBCHK
set feedback off heading off verify off trim on pages 0;
select CDB from v\\$database;
PDBCHK
`
export PDB_DATABASE_CHECK
}

sqlplus_is_present_check(){
# make sure that the sqlplus binary is found
check_for_sqlplus=$(which sqlplus 2>/dev/null)
if [[ ! -f "${check_for_sqlplus}" ]]; then
  echo "The sqlplus binary can't be located."
  echo "It is either not in the PATH setting or it is not installed in the OS."
  echo "Aborting script..."
  exit 1
fi
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
}

handle_error () {
# pass numbers to this function for different errors
# pass 2 arguments to this function; 1st argument is the error code; 2nd argument is the name of the database
ERROR_CODE=$1
DATABASE=$2

case $ERROR_CODE in
  # Error codes 1-10 are for listener or database
  1 ) ERROR_TEXT="FAILED: ${0} - There is no running database on ${HOST}";;
  2 ) ERROR_TEXT="FAILED: ${0} - Container database is not OPEN on ${HOST}";;
  3 ) ERROR_TEXT="WARNING: ${0} - The $2 PDB is not in an OPEN or MOUNTED state.  The check was skipped.";;
  4 ) ERROR_TEXT="WARNING: ${0} - The $2 PDB open_mode check did not pass.  It is not in either the MOUNTED, READ ONLY, or READ WRITE condition.  The check was skipped.";;
esac

ERROR_SUBJECT="Post OS patching Error for $DATABASE on $HOST: ${ERROR_TEXT}"
if [[ $enable_email_alerting != "1" ]];then
  echo "${ERROR_TEXT}"
else
  echo "${ERROR_TEXT}"
  echo "${ERROR_TEXT}" | mailx -s "${ERROR_SUBJECT}" $on_call_email_address
fi
}

database_open_check () {
# check for open database before any other checks execute
# bad things happen if this isn't done as the first check
DATABASE_OPEN_CHECK=$($ORACLE_HOME/bin/sqlplus -S '/ as sysdba' << EOS
set heading off feedback off linesize 150 trim on pages 0;
select status from v\$instance;
exit;
EOS
)

export DATABASE_OPEN_CHECK
}

query_for_dba_registry_sqlpatch () {
  container=$1 # PDB name, if any
  if [[ "$container" ]];then
    target_container="alter session set container=${container};"
  fi
  
  # Execute SQL query
  SQL_RESULT=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << EOF
SET HEADING OFF FEEDBACK OFF TRIM ON;
$target_container
SELECT LTRIM(PATCH_ID) FROM dba_registry_sqlpatch 
WHERE STATUS='SUCCESS'
AND DESCRIPTION like 'Database%Update%'
OR DESCRIPTION like 'Database%Patch%'
ORDER BY ACTION_TIME DESC FETCH FIRST 1 ROWS ONLY;
EXIT;
EOF
`
    #SQL_PATCH=$(echo "$SQL_RESULT" | tr -d '\n' | tr -d ' ')
    SQL_PATCH=$(echo "$SQL_RESULT" | tr -d '\n' | tr -d '[:space:]')
}

check_home_vs_view () {
  role_check_to_use=$1
  if [[ "$DB_PATCH_CHECK_ONE" == "$SQL_PATCH" ]] || [[ "$DB_PATCH_CHECK_TWO" == "$SQL_PATCH" ]]; then
    echo "The patch level in $ORACLE_HOME matches with the database.  Check PASSED for host: ${HOST}"
  else
    echo "WARNING: Database ORACLE_HOME patching mismatch detected for host: ${HOST}"
    if [[ -n "$DB_PATCH_CHECK_ONE" ]];then
      echo "OPatch patch level: $DB_PATCH_CHECK_ONE"
    else
      echo "OPatch patch level: $DB_PATCH_CHECK_TWO"
    fi
    echo "Database patch level: $SQL_PATCH"
    error_count=$(( ${error_count}+1 ))
    if [[ $correct_datapatch_boolean = "1" ]];then
      if [[ ${role_check_to_use} != "PHYSICAL STANDBY" ]];then
        echo "Executing datapatch -verbose.   Please wait..."
        datapatch -verbose
      else
        echo "datapatch -verbose won't be run because this is a physical standby database."
      fi
    fi
  fi
}
# END OF FUNCTIONS


# START MAIN HERE

# set environment for initial checks
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
ORACLE_SID=`grep ^[A-Za-z0-9] $ORATAB | sed 1q | cut -d: -f1`
ORAENV_ASK="NO"
export ORAENV_ASK ORACLE_SID
#echo "ORACLE_SID=${ORACLE_SID}"
PATH=/usr/bin:/bin:/usr/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin
ORACLE_HOME=$(cat $ORATAB | grep -v ^'#' | grep -w "$ORACLE_SID": | cut -d ':' -f 2)
PATH=$PATH:$ORACLE_HOME/bin:$ORACLE_HOME/perl/bin:$ORACLE_HOME/jdk/bin:$ORACLE_HOME/OPatch
#. oraenv
export ORACLE_HOME
LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib:/lib
export PATH LD_LIBRARY_PATH

# track error count
typeset -i error_count
error_count=0

# check ORACLE_SID_LIST array; error if empty
CHECK_ZERO_INDEX_OF_ORACLE_SID_LIST=${ORACLE_SID_LIST[0]}
if [[ -z $CHECK_ZERO_INDEX_OF_ORACLE_SID_LIST ]];then
  echo "No databases are running on ${HOST}"
  handle_error 1
  error_count=$(( ${error_count}+1 ))
fi

# check all ORACLE_SIDs
for ORACLE_SID in ${ORACLE_SID_LIST[@]}
do
  set_environment $ORACLE_SID
  check_for_binary awk
  check_for_binary cut
  check_for_binary date
  check_for_binary grep
  check_for_binary mailx
  check_for_binary ps
  check_for_binary sed
  check_for_binary sort
  check_for_binary uniq
  check_for_binary whoami
  sqlplus_is_present_check
  check_for_OS_authentication
  database_open_check
    
  if [[ ${DATABASE_OPEN_CHECK} != "OPEN" ]];then
    echo "The $ORACLE_SID database isn't in an OPEN state."
    handle_error 2 $ORACLE_SID
    error_count=$(( ${error_count}+1 ))
    continue
  else
    database_role_check
    if [[ ${DATABASE_ROLE_CHECK} != "PHYSICAL STANDBY" ]]; then
      echo "The $ORACLE_SID database has a role of PRIMARY"
    else
      echo "The $ORACLE_SID database has a role of PHYSICAL STANDBY"
    fi
	
	echo "Checking database ORACLE_HOME patching level and the dba_registry_sqlpatch view to see if they match..."
	
	# Parse opatch lspatches
    PATCHES=$($ORACLE_HOME/OPatch/opatch lspatches)
	DB_PATCH_CHECK_ONE=$(echo "$PATCHES" | grep 'Database' | grep 'Update' | tail -1 | awk -F';' '{print $1}')
	DB_PATCH_CHECK_TWO=$(echo "$PATCHES" | grep 'Database' | grep 'Patch' | tail -1 | awk -F';' '{print $1}')

    query_for_dba_registry_sqlpatch
    check_home_vs_view $DATABASE_ROLE_CHECK
  fi

  if [[ "$check_pdbs_boolean" = "1" ]];then
    cdb_pdb_check

  if [[ $PDB_DATABASE_CHECK = "YES" ]]; then
    echo "Container/pluggable database architecture detected.";sleep 1
    #load variable with all PDB values
    PDB_LIST=`$ORACLE_HOME/bin/sqlplus -S "/ as sysdba" << LISTPDB
set feedback off heading off verify off trim on pages 0;
select name from v\\$pdbs where name != 'PDB\\$SEED';
LISTPDB
`

  # build array from list of PDBs
  echo $PDB_LIST | tr ' ' '\n' | { \
    pdb_list_index=0;
    set -A PDB_LIST_ARRAY
    while read PDB_LIST_ITEM
    do
      PDB_LIST_ARRAY[$pdb_list_index]=$PDB_LIST_ITEM
      let pdb_list_index=$pdb_list_index+1
    done;
}

  # check all PDBs in the PDB_LIST if the database is CDB/PDB; else check the non-CDB database
  for pdb_to_check in ${PDB_LIST_ARRAY[@]}
  do
    PDB_OPEN_CHECK=$($ORACLE_HOME/bin/sqlplus -S "/ as sysdba" << PDBOPCHK
set feedback off heading off verify off trim on pages 0;
alter session set container=$pdb_to_check;
select status from v\$instance;
PDBOPCHK
)

    PDB_STATE_CHECK=`$ORACLE_HOME/bin/sqlplus -S "/ as sysdba" << PDBRWCHK
set feedback off heading off verify off trim on pages 0;
alter session set container=$pdb_to_check;
select open_mode from v\\$pdbs where name = '${pdb_to_check}';
PDBRWCHK
`

    if [[ $PDB_OPEN_CHECK = "OPEN" || $PDB_OPEN_CHECK = "MOUNTED" ]] && [[ $PDB_STATE_CHECK = "MOUNTED" || $PDB_STATE_CHECK = "READ WRITE" || $PDB_STATE_CHECK = "READ ONLY" ]];then
      # role check for pluggable
      pluggable_role_check $pdb_to_check
      if [[ $role_check_for_pluggable = 'PHYSICAL STANDBY' ]];then
        echo "The $specified_pluggable_database database is a PHYSICAL STANDBY."
      fi
      # check all PDBs in the container
      echo "Checking PDB: $pdb_to_check patching level and the dba_registry_sqlpatch view to see if they match..."
      query_for_dba_registry_sqlpatch $pdb_to_check
	  check_home_vs_view $role_check_for_pluggable
	else
      if [[ $PDB_OPEN_CHECK != "OPEN" && $PDB_OPEN_CHECK != "MOUNTED" ]];then
	    handle_error 3 $pdb_to_check
	    continue
	  fi
	  if [[ $PDB_STATE_CHECK != "MOUNTED" && $PDB_STATE_CHECK != "READ WRITE" && $PDB_STATE_CHECK != "READ ONLY" ]];then
	    handle_error 4 $pdb_to_check
	    continue
	  fi
	fi
  done
else
  echo "Traditional Oracle database architecture detected."
  echo "There are no PDBs to check.  Checking of PDBs will be skipped.  Please re-execute without using -p or --pdbs"
  exit 0
fi

# "$check_pdbs_boolean" = "1"
fi

# ORACLE_SID in ${ORACLE_SID_LIST[@]}
done

if (( $error_count > 0 ));then
  echo "Errors were encountered on ${HOST}.  Some checks FAILED."
else
  echo "No errors were encountered on ${HOST}.  All checks for this ORACLE_HOME patch level matching what is in dba_registry_sqlpatch PASSED"
fi

exit 0
