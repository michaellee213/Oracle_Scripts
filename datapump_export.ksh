#!/usr/bin/ksh
#
# Title:     datapump_full_export.ksh
# Purpose:   Used to take a datapump full export for the $ORACLE_SID database
#
# Usage:     datapump_full_export.ksh $ORACLE_SID
#            crontab: 5 21 * * * /opt/oracle/admin/scripts/datapump_full_export.ksh -c $ORACLE_SID -p $PDB_ORACLE_SID > /var/opt/oracle/log/datapump_full_export.log 2>&1
#            Runs this every night at 21:05 p.m.
#
# Author:    Michael Lee
# Date:      22DEC2021
#
# Notes:     If an error is encountered, then this script will send an e-mail to youremail@domain.com
#            Requires an oracle directory to be present called DATA_PUMP_DIR which points to 
#            /backup/oracle/dpdump/$ORACLE_SID by default.
#
#            The password value for the DATAPUMP_FULL user has been randomized for every execution of this script, per STIG requirements.  This is only for the datapump exports for the pluggable databases.  Exports for non-CDBs or containers use OS authentication.
#
#            This script uses OS authentication in order to prepare the pluggable database for the datapump job.
#            The datapump job for pluggable database uses SQLNet instead of OS authentication in order to run expdp.
#
#            *BE CAREFUL* - The script will remove dump files from DATA_PUMP_DIR /backup/oracle/dpdump/$ORACLE_SID
#                           that match the find command.  You might wish to adjust the retention period.
#
# Revisions: 18DEC2021 - bug fix for finding correct Oracle home
#            18DEC2021 - added support for container/pluggable architecture and read only Oracle homes.
#            26AUG2022 - added options for tar/gz, parallel setting, and schema level exports
#            1MAY2023 - added option for table level datapump exports
#            15MAY2023 - added pre-checks for existence of either schemas or tables
#                        also added bypass for the pre-checks, just in case
#            21JUN2023 - bug fix for PDB table level exports; added long form command line options and ksh style man page help menu
#
# Runtime:   TBD
# Size:      As of $(date), the size of the .dmp file is TBD
#

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin:/usr/ucb
host=$(hostname)
ostype=$(uname)

# uncomment to enable debug mode
#set -x

# SANITY CHECKS
if [[ $ostype = "SunOS" ]]; then
  ORATAB="/var/opt/oracle/oratab"
elif [[ $ostype = "Linux" ]]; then
  ORATAB="/etc/oratab"
elif [[ $ostype = "HP-UX" ]]; then
  ORATAB="/etc/oratab"
elif [[ $ostype = "AIX" ]]; then
  ORATAB="/etc/oratab"  
fi
if [[ ! -f $ORATAB ]]; then
  echo "No oratab file found!"
  echo "Exiting..."
  exit 1
fi

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
env | grep -v ^'HOME' | grep -v 'eval' | grep -v ^'BASH_FUNC' | grep -v ^'\}' | awk -F'=' '{print $1}' | grep -v 'specified_container_database' | grep -v 'specified_pluggable_database' | grep -v 'disable_email_alerting' | grep -v 'TNS_ADMIN' | grep -v 'parallel_setting_cl' | grep -v 'skip_existence_checks' | grep -v 'schemas_to_export' | grep -v 'tables_to_export' | grep -v 'tar_gz_flag' | grep -v 'working_dir_override' | while read var
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
TODAY_WITH_SECONDS=$(date "+%d%b%Y_%H%M%S")
# dynamic environment variable definitions
ostype=$(uname)
host=$(hostname | cut -d'.' -f1)
# SANITY CHECKS
if [[ $ostype = "SunOS" ]]; then
  ORATAB="/var/opt/oracle/oratab"
elif [[ $ostype = "Linux" ]]; then
  ORATAB="/etc/oratab"
elif [[ $ostype = "HP-UX" ]]; then
  ORATAB="/etc/oratab"
elif [[ $ostype = "AIX" ]]; then
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
# oraenv is not needed, but is here for a sanity check
. oraenv
export ORACLE_HOME
LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib:/lib
export PATH LD_LIBRARY_PATH
export ORACLE_BASE
TMP=/tmp;TEMP=/tmp;TMPDIR=/tmp
export TMP TEMP TMPDIR
if [[ -n $working_dir_override ]];then
  DATA_PUMP_DIR_PATH=$working_dir_override
else
  DATA_PUMP_DIR_PATH="/backup/oracle/dpdump/$ORACLE_SID"
fi

# redundant check for health of DATA_PUMP_DIR_PATH
if [[ ! -d $DATA_PUMP_DIR_PATH ]] || [[ ! -w $DATA_PUMP_DIR_PATH ]];then
  echo "The path being used for the DATA_PUMP_DIR_PATH variable doesn't exist in the OS or isn't writable."
  echo "Exiting..."
  exit 1
fi

export DATA_PUMP_DIR_PATH
EXP_date=`date +%d%b%Y_%H%M`
export EXP_date
EXPORT_RETENTION_IN_DAYS=6
export EXPORT_RETENTION_IN_DAYS
host=$(hostname)

if [[ -n $parallel_setting_cl ]];then
  parallel_setting=$parallel_setting_cl
else
  parallel_setting=4
fi
export parallel_setting

if [[ -n $TNS_ADMIN_override ]];then
  TNS_ADMIN=$TNS_ADMIN_override
else

  # detection for read only Oracle home(s) here
  # check $ORACLE_HOME/install/orabasetab file
  # check label for Oracle home
  LABEL_FOR_ORACLE_HOME=$(cat $ORACLE_HOME/install/orabasetab | grep -v ^'#' | sed '/^$/d' | grep -w $ORACLE_HOME | awk -F':' '{print $3}')
  # use default value for ORACLE_BASE, inherited from the default shell profile
  CHECK_VALUE_FROM_ORABASEHOME=$($ORACLE_HOME/bin/orabasehome)
  if [[ "$CHECK_VALUE_FROM_ORABASEHOME" = "$ORACLE_BASE/homes/$LABEL_FOR_ORACLE_HOME" ]];then
    READ_ONLY_ORACLE_HOME_ENABLED="TRUE"
  fi
  
  if [[ $READ_ONLY_ORACLE_HOME_ENABLED = "TRUE" ]];then
    #set the applicable TNS_ADMIN value if the database is an EBS database or not
    CHECK_TNS_ADMIN=$(echo "$ORACLE_BASE/homes/$LABEL_FOR_ORACLE_HOME/network/admin/${ORACLE_SID}_${host}")
    if [[ -d $CHECK_TNS_ADMIN ]]; then
      echo "This is an EBS Oracle home (but is read only)."
      TNS_ADMIN=$ORACLE_BASE/homes/$LABEL_FOR_ORACLE_HOME/network/admin/${ORACLE_SID}_${host}
    else
      echo "This is not an EBS Oracle home (but is read only)."
      TNS_ADMIN=$ORACLE_BASE/homes/$LABEL_FOR_ORACLE_HOME/network/admin
    fi
  else
    #set the applicable TNS_ADMIN value if the database is an EBS database or not
    CHECK_TNS_ADMIN=$(echo "$ORACLE_HOME/network/admin/${ORACLE_SID}_${host}")
    if [[ -d $CHECK_TNS_ADMIN ]]; then
      echo "This is an EBS Oracle home."
      TNS_ADMIN=$ORACLE_HOME/network/admin/${ORACLE_SID}_${host}
    else
      echo "This is not an EBS Oracle home."
      TNS_ADMIN=$ORACLE_HOME/network/admin
    fi
  # READ_ONLY_ORACLE_HOME_ENABLED
  fi

# TNS_ADMIN_override
fi

export TNS_ADMIN

return
}

usage (){
  echo ""
  echo "Usage: ${0} <options>"
  echo ""
  echo " -c, --container         MANDATORY: if this is specified, then this single instance/container database will be exported"
  echo "                                    use only this option if the database is using traditional architecture and not cdb/pdb"
  echo ""                       
  echo " -p, --pdb                OPTIONAL: if this is specified, then this pluggable database will be exported"
  echo "                                    this option must be used with the -c option"
  echo ""                       
  echo " -d, --disable-email      OPTIONAL: this will disable e-mail alerts"
  echo "                                    and can be used on the command line"
  echo "                                    for testing before this script is deployed as a scheduled job."
  echo ""                       
  echo " -l, --parallel_setting   OPTIONAL: parallel setting for expdp; default is 4; up to 10 is allowed"
  echo "                                    example: -l 10"
  echo ""                       
  echo " -n, --tns-admin          OPTIONAL: this will override the default path for the TNS_ADMIN value"
  echo "                                    this might be needed when performing a full export from a pluggable database"
  echo ""                       
  echo " -r, --skip-prerequisites OPTIONAL: use -r to skip existence pre-checks if the -s (schema) or -t (table) options are used"
  echo "                                    Note: expdp will still attempt to run, but could fail if these checks are skipped"
  echo ""                       
  echo " -s, --schemas            OPTIONAL: specify schema to export; don't use with -t"
  echo "                                    more than 1 can be specified: example: -s SCHEMA1,SCHEMA2"
  echo ""                       
  echo " -t, --tables             OPTIONAL: specify table(s) in schema to export; don't use with -s"
  echo "                                    must be in format of SCHEMA.TABLE"
  echo "                                    must be in format of expdp command line for TABLES=; e.g. \" -s SCHEMA1.TABLE1,SCHEMA1,TABLE2\"" 
  echo ""                       
  echo " -w, --path-for-backup    OPTIONAL: working directory for backup location of datapump export"
  echo "                                    this will override the default value of the DATA_PUMP_DIR_PATH variable"
  echo ""                       
  echo " -z, --gzip               OPTIONAL: tar and gzip the datapump dmp files"
  echo "                                    if this option isn't used, then no dump files will be compressed"
  echo ""                       
  echo " -h, --help                         shows this help"
  echo " --man                              use this with no other arguments for ksh style help menu"
  echo ""
}

# this part is only compatible with ksh 93; won't work on original ksh
USAGE="[-author?Michael Lee ]"
USAGE+="[+NAME?${0} datapump_export.ksh]"
USAGE+="[+DESCRIPTION?Script that can export either full database, schema(s), or table(s).]"
USAGE+="[c:container?Specify which container database to export from.]:[specified_container_database]"
USAGE+="[p:pdb?Specify pluggable database to export from.]:[specified_pluggable_database]"
USAGE+="[d:disable-email?Disable e-mail alerting (default is enabled).]:[disable_email_alerting]"
USAGE+="[h:help?Shows help menu.]"
USAGE+="[l:parallel_setting?Sets the PARALLEL setting for expdp for the export.]#[parallel_setting_cl]"
USAGE+="[n:tns-admin?Specify path for TNS_ADMIN.]:[TNS_ADMIN_override]"
USAGE+="[o:only-check-asm_strings?Only check the ASM disk group string values - will not connect to ASM.]:[only_check_ASM_strings]"
USAGE+="[r:skip-prerequisites?Skip pre-requisite checks prior to export.]:[skip_existence_checks]"
USAGE+="[s:schemas?Schema(s) to export.]:[schemas_to_export]"
USAGE+="[t:tables?Table(s) to export.]:[tables_to_export]"
USAGE+="[w:path-for-backup?Specify path for export location.]:[working_dir_override]"
USAGE+="[z:gzip?Specify this for compressing the dmp and log files with gzip.]:[tar_gz_flag]"
USAGE+=$'\n'

integer parallel_setting=4

while getopts "$USAGE" optchar
do
  case $optchar in
  c  ) specified_container_database=$OPTARG ;; #enable the checking of a specified container database
  d  ) disable_email_alerting=1 ;; #e-mail alerting always on by default; this disables it
  l  ) parallel_setting_cl=$OPTARG ;; #parallel setting up to 10; default is 4
  n  ) TNS_ADMIN_override=$OPTARG ;; # path that will override the default path for the TNS_ADMIN
  p  ) specified_pluggable_database=$OPTARG ;; #enable the checking of a specified pluggable database; must be used with -c
  r  ) skip_existence_checks=1 ;; # skips the existence checks if a schema or table level export has been specified with -s or -t
  s  ) schemas_to_export=$OPTARG ;; # schema(s) level export
  t  ) tables_to_export=$OPTARG ;; # table(s) level export
  w  ) working_dir_override=$OPTARG ;; # different path for dmp file location
  z  ) tar_gz_flag=1 ;; #boolean for using tar and gz for the dmp files; used for space savings
  h  ) usage; exit 0;;
  *  ) echo "Unimplemented option. -$OPTARG" >&2; usage; exit 1;;
  esac
done

#while getopts "c:(container)d(disable-email)h(help)l:(parallel_setting)n:(tns-admin)p:(pdb)r(skip-prerequisites)s:(schemas)t:(tables)w:(path-for-backup)z(gzip)" options;do
#  case $options in
#  c  ) specified_container_database=$OPTARG ;; #enable the checking of a specified container database
#  d  ) disable_email_alerting=1 ;; #e-mail alerting always on by default; this disables it
#  l  ) parallel_setting_cl=$OPTARG ;; #parallel setting up to 10; default is 4
#  n  ) TNS_ADMIN_override=$OPTARG ;; # path that will override the default path for the TNS_ADMIN
#  p  ) specified_pluggable_database=$OPTARG ;; #enable the checking of a specified pluggable database; must be used with -c
#  r  ) skip_existence_checks=1 ;; # skips the existence checks if a schema or table level export has been specified with -s or -t
#  s  ) schemas_to_export=$OPTARG ;; # schema level export
#  t  ) tables_to_export=$OPTARG ;; # table(s) level export
#  w  ) working_dir_override=$OPTARG ;; # different path for dmp file location
#  z  ) tar_gz_flag=1 ;; #boolean for using tar and gz for the dmp files; used for space savings
#  h  ) usage; exit 0;;
#  *  ) echo "Unimplemented option. -$OPTARG" >&2; usage; exit 1;;
#  esac
#done

# validate command line options

# check for the container ORACLE_SID if the -c option is used
if [[ -n $specified_container_database ]];then
  check_container_exists_in_oratab=$(cat $ORATAB | grep -v ^'#' | grep -w "$specified_container_database": | awk -F: '{print $1}')
  if [[ $specified_container_database != $check_container_exists_in_oratab ]];then
    usage
    echo "The specified container database with -c doesn't exist in the oratab.  Exiting..."
    exit 1
  else
    ORACLE_SID=$specified_container_database
    export ORACLE_SID
  fi
else
  usage
  echo "You must specify at least a container database in order to export with datapump (expdp)."
  exit 1
fi

if [[ $disable_email_alerting != "1" ]];then
  echo "E-mail alerts are enabled."
else
  echo "E-mail alerts have been disabled.  No e-mails will be sent."
fi

if [[ -n $specified_pluggable_database ]] && [[ -z $specified_container_database ]];then
  usage
  echo "A pluggable database has been specified without its container."
  echo "If you would like to check a pluggable database, then please specify a container database along with a SID for the container database."
  exit 1
fi

if [[ -n $parallel_setting_cl ]];then
  if [[ ${parallel_setting_cl} -eq ${parallel_setting_cl} ]];then
    if (( $parallel_setting_cl > 10 ));then
	  usage
      echo "The value specified with the -l switch is invalid."
      echo "Please specify an integer between 1 and 10"
      exit 1
	else
	  echo "The expdp PARALLEL setting has been set to $parallel_setting_cl"  
	fi
  else
    usage
    echo "The value specified with the -l switch is invalid."
    echo "Please specify an integer between 1 and 10"
    exit 1
  fi
fi

if [[ -n $TNS_ADMIN_override ]];then
  if [[ ! -d $TNS_ADMIN_override ]];then
    usage
    echo "The path specified for the TNS_ADMIN with -t doesn't exist."
    exit 1
  fi
fi

if [[ -n $schemas_to_export ]] && [[ -n $tables_to_export ]];then
  usage
  echo "Please don't specify both a schema level export and a table level export."
  echo "Specify either -s or -t, but not both.  Please see usage."
  exit 1
fi

if [[ -n $working_dir_override ]];then
  if [[ ! -d $working_dir_override ]] || [[ ! -w $working_dir_override ]];then
    usage
    echo "The path in the OS specified with -w either doesn't exist or isn't writable."
	echo "Exiting..."
	exit 1
  fi
fi
# end of validation for command line options

# FUNCTIONS

database_role_check(){
DATABASE_ROLE_CHECK=$($ORACLE_HOME/bin/sqlplus -S '/ as sysdba' << EOS
set heading off feedback off linesize 150 trim on pages 0;
select database_role from v\$database;
exit;
EOS
)
return
}

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

check_for_data_pump_dir () {
  if [[ ! -d $DATA_PUMP_DIR_PATH ]];then
    if [[ $disable_email_alerting = "1" ]];then
      echo "The directory for DATA_PUMP_DIR doesn't exist in the operating system."
      echo "Please create $DATA_PUMP_DIR_PATH in the operating system before you run this script again."
      exit 1
    else
	  echo "The directory for DATA_PUMP_DIR doesn't exist in the operating system."
      echo "Please create $DATA_PUMP_DIR_PATH in the operating system before you run this script again."
      (
        echo "For the full export of $ORACLE_SID, the $DATA_PUMP_DIR_PATH doesn't exist in the operating system."
        echo "Please create a valid path and make any necessary adjustments to the ${0} script on $host" 
      ) | mailx -s "Datapump full export of $ORACLE_SID has failed due to missing database directory" $on_call_email_address
      exit 1
    fi
  else
    echo "The $DATA_PUMP_DIR_PATH exists in the operating system. Check passed."
  fi
}

check_schema_existence() {
  # Usage: check_schema_existence "<schema1,schema2,schema3>" [PDB_NAME]
  schemas="$1"
  PDB_NAME="$2"
  
  # Save the old IFS and set the new one to comma
  IFS_old=$IFS
  IFS=","
  
   # Convert the list of schemas to an array and construct SQL IN clause
  set -A schema_array $schemas
  for index in ${!schema_array[@]}; do
    schema_array[$index]=$(echo ${schema_array[$index]} | tr '[:lower:]' '[:upper:]')
  done
  in_clause=$(printf ", '%s'" ${schema_array[@]})
  in_clause=${in_clause:2}  # Remove the leading comma and space
  
  # Construct the SQL query
  query="select username from dba_users where username in ($in_clause);"
  
  # Connect to the Oracle database and execute the query
  if [[ -z $PDB_NAME ]];then
    existences=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << CHKSCHMA
      set feedback off heading off verify off trim on pages 0;
      $query
      exit;
CHKSCHMA
)
  else
    existences=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << CHKSCHMA
      set feedback off heading off verify off trim on pages 0;
      alter session set container=$PDB_NAME;
      $query
      exit;
CHKSCHMA
)
  fi

  # Restore the IFS
  IFS=$IFS_old

  # Convert returned schema names to uppercase (for case-insensitive comparison)
  set -A returned_schemas $(echo "$existences" | tr '[:lower:]' '[:upper:]')
  
  # Check existence for each schema
  for schema in ${schema_array[@]}; do
    schema_found=false
    schema_upper=$(echo "$schema" | tr '[:lower:]' '[:upper:]')  # Convert to uppercase
    for returned_schema in ${returned_schemas[@]}; do
      if [[ "$returned_schema" == "$schema_upper" ]]; then
        schema_found=true
        break
      fi
    done
    if $schema_found; then
      echo "$schema schema exists. Check passed."
    else
      echo "$schema schema does not exist. Check failed."
      return 1
    fi
  done
  
  # If all schemas exist, return successfully
  return 0
}

check_table_existence() {
  # Grab tables_to_export from the first argument
  tables_to_export_to_parse=$1
  PDB_NAME=$2
  IFS_backup="$IFS"
 
  # Define IFS for splitting the string into an array
  IFS=","
  set -A tables $tables_to_export_to_parse
  IFS="$IFS_backup"
  
  # Iterate over each table and check its existence
  for table in "${tables[@]}"
  do
    # Parse the schema and table name
    IFS="."
    set -A parsed_table $table
    schema=${parsed_table[0]}
    table_name=${parsed_table[1]}
    IFS="$IFS_backup"
	
  if [[ -z $PDB_NAME ]];then
    # Execute a SQL query to check if the table exists
    result=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << CHKTBL
    set pagesize 0 feedback off verify off heading off echo off;
    select count(*) from dba_tables where owner = '$schema' and table_name = '$table_name';
    exit;
CHKTBL
)
  else
    result=$($ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << CHKTBL
    set pagesize 0 feedback off verify off heading off echo off;
	alter session set container=$PDB_NAME;
    select count(*) from dba_tables where owner = '$schema' and table_name = '$table_name';
    exit;
CHKTBL
)
  fi # -Z $PDB_NAME
  
    # If the table does not exist, print a message and exit with an error code
    if [[ $result -eq 0 ]]
    then
      echo "Table $table does not exist in the database.  Check failed."
      return 1
    else
      echo "Table $table exists in the database.  Check passed."
    fi
  done

  # If all tables exist, return successfully
  return 0
}



# 2 main functions; 1 for non-CDB architecture, 1 for CDB/PDB architecture
# non_pdb_cdb_export
# pdb_cdb_export

non_pdb_cdb_export () {
sqlplus_is_present_check
check_for_OS_authentication
check_for_data_pump_dir

if [[ $skip_existence_checks != "1" ]];then

  # check for schemas first, if they were specified with "-s" (1 or multiple)
  if [[ -n $schemas_to_export ]];then
    # Example usage: check_schema_existence "<schema1,schema2,schema3>" [PDB_NAME]
    # schemas_to_export="HR,SCOTT,TEST"
    # Example usage: check_table_existence <SCHEMA1.TABLE1,SCHEMA2.TABLE2>
    # tables_to_export="SCHEMA1.TABLE1,SCHEMA1.TABLE2"
    check_schema_existence "$schemas_to_export"
    
    # Check the return code of the check_schema_existence function
    if [[ $? -eq 0 ]]
    then
      echo "Check passed: All schemas exist in the database."
    else
      echo "Check failed: One or more schemas do not exist in the database.  Exiting..."
      exit 1
    fi
  
  fi # -n $schemas_to_export

fi # $skip_existence_checks != "1"

if [[ $skip_existence_checks != "1" ]];then

  # check for existence of schemas and tables, if they were specified with "-t" (1 or multiple)
  if [[ -n $tables_to_export ]];then
    # Example usage: check_table_existence <SCHEMA1.TABLE1,SCHEMA2.TABLE2>
    # tables_to_export="SCHEMA1.TABLE1,SCHEMA1.TABLE2"
    check_table_existence "$tables_to_export"
    
    # Check the return code of the check_table_existence function
    if [[ $? -eq 0 ]];then
      echo "Check passed: All tables exist in the database."
    else
      echo "Check failed: One or more tables do not exist in the database.  Exiting..."
      exit 1
    fi
  
  fi # -n $tables_to_export

fi # $skip_existence_checks != "1"

echo "Exporting single instance/container database ${ORACLE_SID}"

# create OR replace the DATA_PUMP_DIR_PATH directory in the database if it exists in the OS
sqlplus -S '/ as sysdba' << EOT
create or replace directory DATA_PUMP_DIR as '$DATA_PUMP_DIR_PATH';
exit;
EOT

# Local OS authentication is used for datapump.
# This may need to change in the future if the multi-threaded model is used.
# In 12C and above, check the database parameter threaded_execution to see if this is enabled
# If it is set to TRUE, then this will fail.
if [[ -n $schemas_to_export ]];then
  schemas_to_export_file=$(echo "$schemas_to_export" | sed s/\,/_/g)
  expdp \"/ as sysdba\" DUMPFILE=${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}_%U.dmp LOGFILE=${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.log DIRECTORY=DATA_PUMP_DIR SCHEMAS=${schemas_to_export} FILESIZE=4G COMPRESSION=ALL PARALLEL=${parallel_setting}
fi

if [[ -n $tables_to_export ]];then
  tables_to_export_file=$(echo "$tables_to_export" | sed s/\,/_/g)
  tables_to_export_file=$(echo "$tables_to_export_file" | tr '.' '_')
  expdp \"/ as sysdba\" DUMPFILE=${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}_%U.dmp LOGFILE=${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.log DIRECTORY=DATA_PUMP_DIR TABLES=${tables_to_export} FILESIZE=4G COMPRESSION=ALL PARALLEL=${parallel_setting}
fi

if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
  expdp \"/ as sysdba\" DUMPFILE=${ORACLE_SID}_full_export_${EXP_date}_%U.dmp LOGFILE=${ORACLE_SID}_full_export_${EXP_date}.log DIRECTORY=DATA_PUMP_DIR FULL=Y FILESIZE=4G COMPRESSION=ALL PARALLEL=${parallel_setting}
fi

# capture the exit code of the datapump job
datapump_exit_code=$?
if [[ "$datapump_exit_code" != "0" ]]; then
  if [[ -n $schemas_to_export ]];then
    echo "The schema level export of ${schemas_to_export} completed with exit code $datapump_exit_code"
  fi
  
  if [[ -n $tables_to_export ]];then
    echo "The table level export of ${tables_to_export} completed with exit code $datapump_exit_code"
  fi

  if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
    echo "The full export of $ORACLE_SID completed with exit code $datapump_exit_code"
  fi
  if [[ $disable_email_alerting != "1" ]];then
    if [[ -n $schemas_to_export ]];then
      echo "The schema level export of ${schemas_to_export_file} completed with exit code $datapump_exit_code" | mailx -s "The schema level export of ${schemas_to_export_file} executed with errors" $on_call_email_address
    fi
  
    if [[ -n $tables_to_export ]];then
      echo "The table level export of ${tables_to_export_file} completed with exit code $datapump_exit_code" | mailx -s "The table level export of ${tables_to_export_file} executed with errors" $on_call_email_address
    fi

    if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
      echo "The full export of $ORACLE_SID completed with exit code $datapump_exit_code" | mailx -s "The full export of $ORACLE_SID completed with exit code $datapump_exit_code" | mailx -s "The full export of $ORACLE_SID executed with errors" $on_call_email_address
    fi
  fi
fi

echo "The datapump exit code was $datapump_exit_code"

# tar and gzip the resulting dump file(s)
if [[ -n $tar_gz_flag ]];then
  echo "Compressing the dump file(s)..."

  # Move to DATA_PUMP_DIR path so that compression operations will succeed
  cd $DATA_PUMP_DIR_PATH

  if [[ -n $schemas_to_export ]];then
    tar -cvf ${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.tar ${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}_*.dmp ${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.log
    gzip ${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.tar
  fi
  
  if [[ -n $tables_to_export ]];then
    tar -cvf ${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.tar ${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}_*.dmp ${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.log
    gzip ${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.tar
  fi

  if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
    tar -cvf ${ORACLE_SID}_full_export_${EXP_date}.tar ${ORACLE_SID}_full_export_${EXP_date}_*.dmp ${ORACLE_SID}_full_export_${EXP_date}.log
    gzip ${ORACLE_SID}_full_export_${EXP_date}.tar
  fi 
      
  # remove the original dump file and log file, the tar'd version is kept
  if [[ -n $schemas_to_export ]];then
    rm ${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}_*.dmp
    rm ${ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.log
  fi

  if [[ -n $tables_to_export ]];then
    rm ${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}_*.dmp
    rm ${ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.log
  fi

  if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
    rm ${ORACLE_SID}_full_export_${EXP_date}_*.dmp
    rm ${ORACLE_SID}_full_export_${EXP_date}.log
  fi
fi

# Cleanup of old dump and log files
# .dmp and .tar.gz files are in $DATA_PUMP_DIR_PATH
  
## Retention of old dump files is set to 6 days or whatever is set with the EXPORT_RETENTION_IN_DAYS variable above
## check the count of successfully completed gz files, more than 0 bytes
## this is so only successful exports are deleted
#typeset -i SUCCESSFUL_EXPORT_ARCHIVE_COUNT
#SUCCESSFUL_EXPORT_ARCHIVE_COUNT=$(find $DATA_PUMP_DIR_PATH -name \*.gz -size +0 | wc -l)
#if (( $SUCCESSFUL_EXPORT_ARCHIVE_COUNT >= $EXPORT_RETENTION_IN_DAYS )); then
#  # only delete if there are enough full exports that completed successfully
#  find $DATA_PUMP_DIR_PATH -name "${ORACLE_SID}_full_export_*.tar.gz" -mtime +$EXPORT_RETENTION_IN_DAYS -exec rm {} \;
#fi
  
echo "The datapump job for $ORACLE_SID has completed"

return
# non_pdb_cdb_export
}

pdb_cdb_export () {
# use the first argument to this function as the value for the PDB
PDB_ORACLE_SID=$1

sqlplus_is_present_check
check_for_OS_authentication
check_for_data_pump_dir

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
    echo "The $specified_pluggable_database database is a PHYSICAL STANDBY and won't be exported with datapump (expdp)."
    exit 1
  fi

  echo "Exporting pluggable database ${PDB_ORACLE_SID}"

# export logic/instructions for pluggable goes here

# check for TNS definition for specified pluggable database
tnsping $specified_pluggable_database
exit_code_for_tnsping=$?
if [[ $exit_code_for_tnsping != "0" ]];then
  echo "The tnsping test for $specified_pluggable_database failed."
  echo "Make sure that a TNS definition has been specified for $specified_pluggable_database in the tnsnames.ora file or its ifile."
  echo "The TNS_ADMIN is set to $TNS_ADMIN"
  exit 1
else
  echo "The tnsping test for $specified_pluggable_database passed."
  echo ""
fi

if [[ $skip_existence_checks != "1" ]];then

  # check for schemas first, if they were specified with "-s" (1 or multiple)
  if [[ -n $schemas_to_export ]];then
  
    # Example usage: check_schema_existence "<schema1,schema2,schema3>" [PDB_NAME]
    # schemas_to_export="HR,SCOTT,TEST"
    
    check_schema_existence "$schemas_to_export" $PDB_ORACLE_SID
	
    # Check the return code of the check_schema_existence function
    if [[ $? -eq 0 ]]
    then
      echo "Check passed: All schemas exist in the database."
    else
      echo "Check failed: One or more schemas do not exist in the database.  Exiting..."
      exit 1
    fi
    
  fi # -n $schemas_to_export

fi # $skip_existence_checks != "1"

if [[ $skip_existence_checks != "1" ]];then

  # check for existence of schemas and tables, if they were specified with "-t" (1 or multiple)
  if [[ -n $tables_to_export ]];then
    # Example usage: check_table_existence <SCHEMA1.TABLE1,SCHEMA2.TABLE2>
    # tables_to_export="SCHEMA1.TABLE1,SCHEMA1.TABLE2"
    check_table_existence "$tables_to_export" "$PDB_ORACLE_SID"
    
    # Check the return code of the check_table_existence function
    if [[ $? -eq 0 ]]
    then
      echo "Check passed: All tables exist in the database."
    else
      echo "Check failed: One or more tables do not exist in the database.  Exiting..."
      exit 1
    fi
  
  fi # -n $tables_to_export

fi # $skip_existence_checks != "1"

# create OR replace the DATA_PUMP_DIR_PATH directory in the database if it exists in the OS
sqlplus -S '/ as sysdba' << DPDPCREA
create or replace directory DATA_PUMP_DIR as '$DATA_PUMP_DIR_PATH';
exit;
DPDPCREA


#infinite loop guard; if the counter goes too high, then abort script
typeset -i creation_of_datapump_full_user_loop_counter
creation_of_datapump_full_user_loop_counter=0

while [[ $DATAPUMP_FULL_USER_CREATED != "TRUE" ]]
do

  #infinite loop guard; if the counter goes too high, then abort script
  typeset -i random_password_generation_infinite_loop_counter
  random_password_generation_infinite_loop_counter=0

  # infinite loop for the population of the RANDOM_PASSWORD_FOR_DATAPUMP_FULL password value
  # until we get a value that meets the password policy
  while true;do
  # generate random password for DATAPUMP_FULL user
  RANDOM_PASSWORD_FOR_DATAPUMP_FULL=$(cat /dev/urandom | tr -dc '[:alnum:]' | fold -w 12 | head -1 | sed 's/./&_/g;s/_$//')
  export RANDOM_PASSWORD_FOR_DATAPUMP_FULL
  # check for character counts; make sure that the password meets the password policy
  # minimum 4 uppercase letters, 4 lowercase letters, and 4 digits
  LOWER_CHARS="abcdefghijklmnopqrstuvwxyz"
  UPPER_CHARS="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  NUMBER_CHARS="0123456789"
  # no need to check for special character counts because most of the random password will be offset underscores
  
  typeset -i CHARS_LOWER_CHECK
  typeset -i CHARS_UPPER_CHECK
  typeset -i CHARS_NUMBER_CHECK
  
  CHARS_LOWER_CHECK=$(echo "$RANDOM_PASSWORD_FOR_DATAPUMP_FULL" | tr -cd "$LOWER_CHARS" | wc -m | awk '{print $1}')
  if (( $CHARS_LOWER_CHECK > 3 ));then
    CHARS_LOWER_PASSED="TRUE"
  fi
  
  CHARS_UPPER_CHECK=$(echo "$RANDOM_PASSWORD_FOR_DATAPUMP_FULL" | tr -cd "$UPPER_CHARS" | wc -m | awk '{print $1}')
  if (( $CHARS_UPPER_CHECK > 3 )); then
    CHARS_UPPER_PASSED="TRUE"
  fi
  
  CHARS_NUMBER_CHECK=$(echo "$RANDOM_PASSWORD_FOR_DATAPUMP_FULL" | tr -cd "$NUMBER_CHARS" | wc -m | awk '{print $1}')
  if (( $CHARS_NUMBER_CHECK > 3 ));then
    CHARS_NUMBER_PASSED="TRUE"
  fi
  
  if [[ $CHARS_LOWER_PASSED = "TRUE" ]] && [[ $CHARS_UPPER_PASSED = "TRUE" ]] && [[ $CHARS_NUMBER_PASSED = "TRUE" ]];then
    echo "The randomly generated password for the DATAPUMP_FULL user has passed all checks."
    break
  fi
  
  random_password_generation_infinite_loop_counter_abort_threshold=50000
  let random_password_generation_infinite_loop_counter=$random_password_generation_infinite_loop_counter+1
  if [[ $random_password_generation_infinite_loop_counter = $random_password_generation_infinite_loop_counter_abort_threshold ]];then
    echo "The random_password_generation_infinite_loop_counter_abort_threshold of $random_password_generation_infinite_loop_counter_abort_threshold has been reached.  The script has been aborted."
    exit 1
  fi

  done

# create user just for the full export of the pluggable database
sqlplus -S '/ as sysdba' << CREADPUS
alter session set container=$PDB_ORACLE_SID;
DROP USER DATAPUMP_FULL;
CREATE USER DATAPUMP_FULL IDENTIFIED BY "$RANDOM_PASSWORD_FOR_DATAPUMP_FULL" ACCOUNT UNLOCK;
exit;
CREADPUS

# check for existence of DATAPUMP_FULL user in pluggable database
CHECK_FOR_EXISTENCE_OF_DATAPUMP_FULL=$(sqlplus -S '/ as sysdba' << CREADPUS
set heading off feedback off linesize 150 trim on pages 0;
alter session set container=$PDB_ORACLE_SID;
select username from dba_users where username = 'DATAPUMP_FULL';
exit;
CREADPUS
)

if [[ $CHECK_FOR_EXISTENCE_OF_DATAPUMP_FULL = "DATAPUMP_FULL" ]];then
  echo "The existence of the DATAPUMP_FULL database user has been verified in the $PDB_ORACLE_SID pluggable database. Check passed."
  DATAPUMP_FULL_USER_CREATED="TRUE"
  break
else
  echo "The creation of the DATAPUMP_FULL user in the $PDB_ORACLE_SID pluggable database has failed."
  echo "Check this script in debug mode in order to troubleshoot the problem."
  exit 1
fi

create_of_datapump_full_infinite_loop_abort_threshold=3
let creation_of_datapump_full_user_loop_counter=$creation_of_datapump_full_user_loop_counter+1
if [[ $creation_of_datapump_full_user_loop_counter = $create_of_datapump_full_infinite_loop_abort_threshold ]];then
  echo "The create_of_datapump_full_infinite_loop_abort_threshold of $create_of_datapump_full_infinite_loop_abort_threshold has been reached.  The script has been aborted."
  exit 1
fi

# $DATAPUMP_FULL_USER_CREATED != "TRUE"
done

# issue grants to DATAPUMP_FULL user
sqlplus -S '/ as sysdba' << GRANDPUS
alter session set container=$PDB_ORACLE_SID;
GRANT CONNECT TO DATAPUMP_FULL;
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO DATAPUMP_FULL;
GRANT DATAPUMP_EXP_FULL_DATABASE TO DATAPUMP_FULL;
ALTER USER DATAPUMP_FULL QUOTA UNLIMITED ON USERS;
ALTER USER DATAPUMP_FULL DEFAULT TABLESPACE USERS;
GRANT DBA TO DATAPUMP_FULL;
exit;
GRANDPUS

# check to make sure that the SQLNet connection to the pluggable database
# is actually connecting to a pluggable database
typeset -i PDB_SEED_COUNT
PDB_SEED_COUNT=$($ORACLE_HOME/bin/sqlplus -S DATAPUMP_FULL/$RANDOM_PASSWORD_FOR_DATAPUMP_FULL@$PDB_ORACLE_SID << PDBSDCNT
set heading off feedback off linesize 150 trim on pages 0;
select count(*) from v\$pdbs where name = 'PDB\$SEED';
exit;
PDBSDCNT
)

# 0 rows should be returned for PDB_SEED_COUNT if the connection was to a pluggable database
if (( $PDB_SEED_COUNT > 0 ));then
  echo "The $PDB_ORACLE_SID database is not a pluggable database."
  echo "The TNS definition defined for $PDB_ORACLE_SID is pointed to a single instance/container database."
  echo "Please check the TNS definition for $PDB_ORACLE_SID"
  exit 1
fi

# SQLNet authentication is used for datapump for a pluggable database.
if [[ -n $schemas_to_export ]];then
  schemas_to_export_file=$(echo "$schemas_to_export" | sed s/\,/_/g)
  expdp DATAPUMP_FULL/$RANDOM_PASSWORD_FOR_DATAPUMP_FULL@$PDB_ORACLE_SID DUMPFILE=${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}_%U.dmp LOGFILE=${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.log DIRECTORY=DATA_PUMP_DIR SCHEMAS=${schemas_to_export} FILESIZE=4G COMPRESSION=ALL PARALLEL=${parallel_setting}
fi

if [[ -n $tables_to_export ]];then
  tables_to_export_file=$(echo "$tables_to_export" | sed s/\,/_/g)
  tables_to_export_file=$(echo "$tables_to_export_file" | tr '.' '_')
  expdp DATAPUMP_FULL/$RANDOM_PASSWORD_FOR_DATAPUMP_FULL@$PDB_ORACLE_SID DUMPFILE=${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}_%U.dmp LOGFILE=${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.log DIRECTORY=DATA_PUMP_DIR TABLES=${tables_to_export} FILESIZE=4G COMPRESSION=ALL PARALLEL=${parallel_setting}
fi

if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
  expdp DATAPUMP_FULL/$RANDOM_PASSWORD_FOR_DATAPUMP_FULL@$PDB_ORACLE_SID DUMPFILE=${PDB_ORACLE_SID}_full_export_${EXP_date}_%U.dmp LOGFILE=${PDB_ORACLE_SID}_full_export_${EXP_date}.log DIRECTORY=DATA_PUMP_DIR FULL=Y FILESIZE=4G COMPRESSION=ALL PARALLEL=${parallel_setting}
fi

# capture the exit code of the datapump job
datapump_exit_code=$?
if [[ "$datapump_exit_code" != "0" ]]; then
  if [[ -n $schemas_to_export ]];then
    echo "The schema level export of ${schemas_to_export} completed with exit code $datapump_exit_code"
  fi
  
  if [[ -n $tables_to_export ]];then
    echo "The table level export of ${tables_to_export} completed with exit code $datapump_exit_code"
  fi

  if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
    echo "The full export of $PDB_ORACLE_SID completed with exit code $datapump_exit_code"
  fi
  if [[ $disable_email_alerting != "1" ]];then
    if [[ -n $schemas_to_export ]];then
      echo "The schema level export of ${schemas_to_export_file} completed with exit code $datapump_exit_code" | mailx -s "The schema level export of ${schemas_to_export_file} executed with errors" $on_call_email_address
    fi
  
    if [[ -n $tables_to_export ]];then
      echo "The table level export of ${tables_to_export_file} completed with exit code $datapump_exit_code" | mailx -s "The table level export of ${tables_to_export_file} executed with errors" $on_call_email_address
    fi

    if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
      echo "The full export of $PDB_ORACLE_SID completed with exit code $datapump_exit_code" | mailx -s "The full export of $PDB_ORACLE_SID completed with exit code $datapump_exit_code" | mailx -s "The full export of $PDB_ORACLE_SID executed with errors" $on_call_email_address
    fi
  fi
fi

echo "The datapump exit code was $datapump_exit_code"

if [[ -n $tar_gz_flag ]];then
  echo "Compressing the dump file(s)..."
  
  # Move to DATA_PUMP_DIR path so that compression operations will succeed
  cd $DATA_PUMP_DIR_PATH
  
  # tar the resulting dump file

  if [[ -n $schemas_to_export ]];then
    tar -cvf ${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.tar ${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}_*.dmp ${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.log
    gzip ${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.tar
  fi
  
  if [[ -n $tables_to_export ]];then
    tar -cvf ${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.tar ${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}_*.dmp ${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.log
    gzip ${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.tar
  fi

  if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
    tar -cvf ${PDB_ORACLE_SID}_full_export_${EXP_date}.tar ${PDB_ORACLE_SID}_full_export_${EXP_date}_*.dmp ${PDB_ORACLE_SID}_full_export_${EXP_date}.log
    gzip ${PDB_ORACLE_SID}_full_export_${EXP_date}.tar
  fi 

  # remove the original dump file and log file, the tar'd version is kept
  if [[ -n $schemas_to_export ]];then
    rm ${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}_*.dmp
    rm ${PDB_ORACLE_SID}_${schemas_to_export_file}_schema_${EXP_date}.log
  fi

  if [[ -n $tables_to_export ]];then
    rm ${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}_*.dmp
    rm ${PDB_ORACLE_SID}_${tables_to_export_file}_tables_${EXP_date}.log
  fi

  if [[ -z $schemas_to_export ]] && [[ -z $tables_to_export ]];then
    rm ${PDB_ORACLE_SID}_full_export_${EXP_date}_*.dmp
    rm ${PDB_ORACLE_SID}_full_export_${EXP_date}.log
  fi
fi

# Cleanup of old dump and log files
# .dmp and .tar.gz files are in $DATA_PUMP_DIR_PATH
  
## Retention of old dump files is set to 6 days or whatever is set with the EXPORT_RETENTION_IN_DAYS variable above
## check the count of successfully completed gz files, more than 0 bytes
## this is so only successful exports are deleted
#typeset -i SUCCESSFUL_EXPORT_ARCHIVE_COUNT
#SUCCESSFUL_EXPORT_ARCHIVE_COUNT=$(find $DATA_PUMP_DIR_PATH -name \*.gz -size +0 | wc -l)
#if (( $SUCCESSFUL_EXPORT_ARCHIVE_COUNT >= $EXPORT_RETENTION_IN_DAYS )); then
#  # only delete if there are enough full exports that completed successfully
#  find $DATA_PUMP_DIR_PATH -name "${ORACLE_SID}_full_export_*.tar.gz" -mtime +$EXPORT_RETENTION_IN_DAYS -exec rm {} \;
#fi

echo "Cleaning up the DATAPUMP_FULL user in the $PDB_ORACLE_SID database..."
sqlplus -S '/ as sysdba' << DELDPUS
alter session set container=$PDB_ORACLE_SID;
DROP USER DATAPUMP_FULL;
exit;
DELDPUS
  
echo "The datapump job for $ORACLE_SID has completed"

else
  echo "The $PDB_ORACLE_SID database isn't in an OPEN or MOUNTED state."
  echo "The $PDB_ORACLE_SID database was in $PDB_OPEN_CHECK mode when checking v\$instance"
  echo "The database was in $PDB_STATE_CHECK mode when checking v\$pdbs"
  echo "Aborting export of $PDB_ORACLE_SID"
# DATABASE_OPEN_CHECK OPEN or MOUNTED
fi

return
# pdb_cdb_export
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

# END OF FUNCTIONS



# START MAIN HERE

if [[ -n $specified_container_database ]] && [[ -z $specified_pluggable_database ]];then
# default behavior, with no command line options for any specific database, is to check all running databases on the server

  set_environment $ORACLE_SID
  check_for_binary awk
  check_for_binary cut
  check_for_binary date
  check_for_binary expdp
  check_for_binary grep
  check_for_binary gzip
  check_for_binary mailx
  check_for_binary ps
  check_for_binary sed
  check_for_binary tar
  check_for_binary tr
  check_for_binary whoami
  sqlplus_is_present_check
  check_for_OS_authentication
  database_open_check

  if [[ ${DATABASE_OPEN_CHECK} = "OPEN" ]] || [[ ${DATABASE_OPEN_CHECK} = "MOUNTED" ]]; then
    database_role_check

    if [[ ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY" ]]; then
      echo "The $ORACLE_SID database is a PHYSICAL STANDBY and won't exported with datapump (expdp)."
      exit 1
    else
      echo "Traditional Oracle database architecture detected.";sleep 1
      non_pdb_cdb_export
    # ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY"
    fi

  else
    echo "The $ORACLE_SID database isn't in an OPEN state."
    echo "Aborting the export of the $specified_container_database database."
    echo "Exiting..."
    exit 1
  # DATABASE_OPEN_CHECK OPEN or MOUNTED
  fi

# [[ -n $specified_container_database ]] && [[ -z $specified_pluggable_database ]]
fi


if [[ -n $specified_container_database ]] && [[ -n $specified_pluggable_database ]]; then
  echo "Command line settings for exporting a pluggable database have been specified."
  echo "Exporting pluggable database $specified_pluggable_database"
  # check for container database in running processes
  check_specified_container_present_in_running_processes
  set_environment $specified_container_database
  check_for_binary awk
  check_for_binary cut
  check_for_binary date
  check_for_binary expdp
  check_for_binary fold
  check_for_binary grep
  check_for_binary gzip
  check_for_binary mailx
  check_for_binary ps
  check_for_binary sed
  check_for_binary tar
  check_for_binary tr
  check_for_binary tnsping
  check_for_binary whoami
  sqlplus_is_present_check
  check_for_OS_authentication
  database_open_check

  if [[ ${DATABASE_OPEN_CHECK} = "OPEN" ]] || [[ ${DATABASE_OPEN_CHECK} = "MOUNTED" ]]; then
    database_role_check
    if [[ ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY" ]]; then
      usage
      echo "The $ORACLE_SID database is a PHYSICAL STANDBY and won't be exported with datapump (expdp)."
      exit 1
    fi
  else
    usage
    echo "The $ORACLE_SID database isn't in an OPEN state."
    echo "Aborting the export of the $specified_pluggable_database database."
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
    echo "You have specified a pluggable database, but this database is traditional single instance/container."
    exit 1
  fi

  echo "Exporting pluggable database: $specified_pluggable_database"
  pdb_cdb_export $specified_pluggable_database
  
# -n $specified_container_database && -n $specified_pluggable_database
fi

exit 0
