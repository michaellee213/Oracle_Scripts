#!/bin/ksh
# Title:        cleanup_and_disable_auto_stats_advisor_task.ksh
# Purpose:      This script will cleanup the SYS.WRI$_ADV_OBJECTS table and removes the AUTO_STATS_ADVISOR_TASK with DBMS_STATS.DROP_ADVISOR_TASK.
#
# Usage:        cleanup_and_disable_auto_stats_advisor_task.ksh -c <$ORACLE_SID>
# Crontab:      0 3 2 * * /backup/scripts/cleanup_and_disable_auto_stats_advisor_task.ksh > /var/tmp/cleanup_and_disable_auto_stats_advisor_task.log 2>&1
#               This example cron entry would run this script run monthly, on the 2nd of the month, at 3 a.m.
#
# Author:       Michael Lee
# Created on:   27APR2023
#
# Notes:        This solution for addressing large space usage in the SYSAUX tablespace by the SYS.WRI$_ADV_OBJECTS table comes directly from Oracle Support in this document: SYSAUX Tablespace Grows Rapidly After Upgrading Database to 12.2.0.1 or Above Due To Statistics Advisor (Doc ID 2305512.1)
#               https://support.oracle.com/epmos/faces/DocContentDisplay?id=2305512.1
#               
#               PDB/CDB architecture is supported, but only the PDBs are changed with this script.  The CDB is left unmodified.
#
#               If you specify a cdb without a specific pdb, then this sql is executed in all pdbs with the exception of the PDB$SEED pdb.
#               If non-CDB architecture is still being used, then the SQL is only executed in the traditional/non-CDB database (what is now known as CDB$ROOT in PDB/CDB architecture)
#
#               If you specify a specific pdb, then you must specify its container.  If a specific pdb is specified with -p, then the sql for this task will only be executed in the PDB specified with "-p".
#
#               UNTESTED IN 12C, BUT WORKS PERFECTLY IN 19C.  USE IN 12C AT YOUR OWN RISK.  IT SHOULD WORK, BUT TEST IN A 12C INSTANCE FIRST AND MAKE SURE THAT THE INSERT STATEMENTS DON'T EXECUTE TWICE.
#
# Revisions:    27APR2023 - first draft
#               1MAY2023 - added no_unnest push_subq optimizer hint for the creation of the WRI$_ADV_OBJECTS_NEW table - performance improvement of table creation by over 10x
#                           
# Instructions: Deploy to any database server for cleaning up the SYS.WRI$_ADV_OBJECTS table for the AUTO_STATS_ADVISOR_TASK advisor task for all pdbs or one pdb
#               You must run this script on either the Linux or SunOS platform.  Some legacy code is commented out for Solaris.
#               Be sure to change the value of the on_call_email_address as appropriate. (on or near line 96)
#
#               Check the output in debug mode to make sure that the initial rollout/execution has gone smoothly.
#
#               This script can be implemented in the crontab, OEM, or Cloud Control
#               Don't forget to convert the EOL format to Linux/Unix
#
#               In Notepad++, Edit, EOL Conversion (or)
#
#               vi cleanup_and_disable_auto_stats_advisor_task.ksh
#               :set ff=unix
#               :wq
#
# Runtime:      As of 27APR2023, the runtime for this sql can be up to 10 to 15 minutes in one PDB if the SYS.WRI$_ADV_OBJECTS table is large (20+ GB).
#               If executing in all PDBs in a CDB, then this execution can take more than 1 hour, depending on the number of PDBs.
#
# Size:         The produced log files won't accumulate since they are overwritten on every execution of this script.
#########################################################################################

#set -x

on_call_email_address="youremail@domain.com"

ostype=$(uname)
# SANITY CHECKS
if [[ $ostype = "SunOS" ]]; then
  ORATAB="/var/opt/oracle/oratab"
elif [[ $ostype = "Linux" ]]; then
  ORATAB="/etc/oratab"
elif [[ $ostype = "HP-UX" ]]; then
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

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/ccs/bin:/usr/sfw/bin:/usr/ucb

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
env | grep -v ^'HOME' | awk -F'=' '{print $1}' | grep -v 'disable_email_alerting' | grep -v 'specified_container_database' | grep -v 'specified_pluggable_database' | while read var
do
  unset $var 2>/dev/null
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
fi
if [[ ! -f $ORATAB ]]; then
  echo "No oratab file found!"
  echo "Exiting..."
  exit 1
fi

# Make sure that the oratab is populated with at least one entry
# this check won't work in AIX ksh and will need to be commented
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
. oraenv
export ORACLE_HOME
LD_LIBRARY_PATH=$ORACLE_HOME/lib:/usr/lib:/lib
export PATH LD_LIBRARY_PATH
# this seems to be a universal location regardless of the platform used for ADR_BASE and ORACLE_BASE
# the diagnostic_dest parameter in every database listed in the Oracle home will be checked for redundancy
# make sure to change this if your environment has different values
#ORACLE_BASE="/u01/app"
#export ORACLE_BASE
TMP=/tmp;TEMP=/tmp;TMPDIR=/tmp
export TMP TEMP TMPDIR
LOAD_DATE=`date +%d%b%Y_%H%M%S`
export LOAD_DATE
#DEPLOY_JOBS_LOG_PATH="/home/oracle"
## remove trailing slash
#DEPLOY_JOBS_LOG_PATH=${DEPLOY_JOBS_LOG_PATH%/}
#export DEPLOY_JOBS_LOG_PATH
#DEPLOY_JOBS_LOG_FILE="${DEPLOY_JOBS_LOG_PATH}/deploy_aud_trail_jobs_${LOAD_DATE}.log"
#export DEPLOY_JOBS_LOG_FILE
return
}

handle_error () {
# pass error code to this function
ERROR_CODE=$1
DB_STRING_VALUE=$2

case $ERROR_CODE in
  1 ) ERROR_TEXT="";;
esac

ERROR_SUBJECT="$DB_VALUE - Problem cleaning up the AUTO_STATS_ADVISOR_TASK advisor task on $host"
if [[ $disable_email_alerting = "1" ]];then
  echo "${ERROR_TEXT}"
else
  echo "${ERROR_TEXT}"
  echo "${ERROR_TEXT}" | mailx -s "${ERROR_SUBJECT}" $on_call_email_address
fi

# don't exit in case iteration is being done for all pdbs
# exit 1
}

usage (){
  echo ""
  echo "Usage: ${0} <options>"
  echo ""
  echo " -c   OPTIONAL: if this is specified, then this single instance/container database will be checked"
  echo "                use only this option if the database is using traditional architecture and not cdb/pdb"
  echo ""
  echo " -p   OPTIONAL: if this is specified, then this pluggable database will be loaded"
  echo "                this option must be used with the -c option"
  echo ""
  echo " -d   OPTIONAL: this will disable e-mail alerts"
  echo "                and can be used on the command line"
  echo "                for testing before this script is deployed as a scheduled job."
  echo ""
  echo " -h             shows this help"
  echo ""
}

while getopts "c:dhp:" options;do
  case $options in
  c  ) specified_container_database=$OPTARG ;; #enable the checking of a specified container database
  d  ) disable_email_alerting=1 ;; #e-mail alerting always on by default; this disables it
  p  ) specified_pluggable_database=$OPTARG ;; #enable the checking of a specified pluggable database; must be used with -c
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
  echo "You must specify at least a container database in order to automatically clean up the SYS.WRI$_ADV_OBJECTS table and remove the AUTO_STATS_ADVISOR_TASK advisor task."
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

check_for_binary=$(which $1)
if [[ "${check_for_binary}" = "" ]];then
  echo "The ${1} binary can't be located."
  echo "It is either not in the PATH setting or it is not installed in the OS."
  echo "Aborting script..."
  exit 1
fi
return
}

# 2 main functions; 1 for non-CDB architecture, 1 for CDB/PDB architecture
# deploy_auto_stats_advisor_fix_non_cdb
# pdb_cleanup_and_disable_auto_stats_advisor

deploy_auto_stats_advisor_fix_non_cdb () {
sqlplus_is_present_check
check_for_OS_authentication

# deploy cleanup for the SYS.WRI$_ADV_OBJECTS table and removal of the AUTO_STATS_ADVISOR_TASK advisor task

$ORACLE_HOME/bin/sqlplus -S "/ as sysdba" << CLEANUP
set feedback on heading on verify off trim on pages 2000 linesize 200;

show con_name;
select SYSTIMESTAMP FROM DUAL;
PRO TS_NAME,MEGS_ALLOC,MEGS_FREE,MEGS_USED,PCT_FREE,PCT_USED,USED_PCT_OF_MAX,MAX_MB,STATUS,CONTENTS	
select * from ( 
       select ltrim(rtrim(a.tablespace_name)) || ',' ||
       round(a.bytes_alloc / 1024 / 1024) /* megs_alloc */ || ',' ||
       round(nvl(b.bytes_free, 0) / 1024 / 1024) /* megs_free */ || ',' ||
       round((a.bytes_alloc - nvl(b.bytes_free, 0)) / 1024 / 1024) /* megs_used */ || ',' ||
       round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100) /* Pct_Free */ || '%,' ||
       trim(100 - round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100)) /* Pct_used */ || '%,' ||
       round((((a.bytes_alloc - nvl(b.bytes_free, 0))) / round(maxbytes)) * 100) /* USED_PCT_OF_MAX */ || '%,' ||
       round(maxbytes/1048576) || ',' ||
       c.status || ',' ||
       c.contents
from  ( select  f.tablespace_name,
               sum(f.bytes) bytes_alloc,
               sum(decode(f.autoextensible, 'YES',f.maxbytes,'NO', f.bytes)) maxbytes
        from dba_data_files f
        group by tablespace_name) a,
      (
             select ts.name tablespace_name, sum(fs.blocks) * ts.blocksize bytes_free
             from   DBA_LMT_FREE_SPACE fs, sys.ts$ ts
             where  ts.ts# = fs.tablespace_id
             group by ts.name, ts.blocksize
      ) b,
      dba_tablespaces c
where a.tablespace_name = b.tablespace_name (+)
and a.tablespace_name = c.tablespace_name
union all
select ltrim(rtrim(h.tablespace_name)) || ',' ||
       round(sum(h.bytes_free + h.bytes_used) / 1048576) /* megs_alloc */ || ',' ||
       round(sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / 1048576) /* megs_free */ || ',' ||
       round(sum(nvl(p.bytes_used, 0))/ 1048576) /* megs_used */ || ',' ||
       round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100) /* Pct_Free */ || ',' ||
       trim(100 - round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100)) /* pct_used */ || ',' ||
       round(sum(nvl(p.bytes_used, 0)) / round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes))) * 100) /* USED_PCT_OF_MAX */ || ',' ||
       round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes) / 1048576)) /* max */ || ',' ||
       c.status || ',' ||
       c.contents
from   sys.v_\$TEMP_SPACE_HEADER h,
       sys.v_\$Temp_extent_pool p,
       dba_temp_files f,
      dba_tablespaces c
where  p.file_id(+) = h.file_id
and    p.tablespace_name(+) = h.tablespace_name
and    f.file_id = h.file_id
and    f.tablespace_name = h.tablespace_name
and f.tablespace_name = c.tablespace_name
group by h.tablespace_name, c.status, c.contents)
order by 1;

PRO Checking number of rows in WRI\$_ADV_OBJECTS for the AUTO_STATS_ADVISOR_TASK
-- ### Check the no.of rows in WRI$_ADV_OBJECTS for Auto Stats Advisor Task ###
SELECT COUNT(*) FROM WRI\$_ADV_OBJECTS WHERE TASK_ID=(SELECT /*+ no_unnest push_subq */ DISTINCT ID FROM WRI\$_ADV_TASKS WHERE NAME='AUTO_STATS_ADVISOR_TASK');

SELECT SYSTIMESTAMP FROM DUAL;

PRO Creating table WRI\$_ADV_OBJECTS_NEW as SELECT * FROM WRI\$_ADV_OBJECTS...
-- ### Do CTAS from WRI$_ADV_OBJECTS to keep the rows apart from AUTO_STATS_ADVISOR_TASK ###
CREATE TABLE WRI\$_ADV_OBJECTS_NEW AS SELECT * FROM WRI\$_ADV_OBJECTS WHERE TASK_ID !=(SELECT /*+ no_unnest push_subq */ DISTINCT ID FROM WRI\$_ADV_TASKS WHERE NAME='AUTO_STATS_ADVISOR_TASK');

SELECT SYSTIMESTAMP FROM DUAL;

PRO Count of WRI\$_ADV_OBJECTS_NEW
SELECT COUNT(*) FROM WRI\$_ADV_OBJECTS_NEW;

-- ### Truncate the table ###
PRO Truncating WRI\$_ADV_OBJECTS table...
TRUNCATE TABLE WRI\$_ADV_OBJECTS;

-- ### Insert the rows from backed up table WRI$_ADV_OBJECTS_NEW to restore the records of the advisor objects ###
PRO Inserting rows from backed up table WRI\$_ADV_OBJECTS_NEW to restore the records of the advisor objects...
INSERT /*+ APPEND */ INTO WRI\$_ADV_OBJECTS SELECT * FROM WRI\$_ADV_OBJECTS_NEW;
-- For 19c & above, use the below insert statement to avoid ORA-54013 error as there is a new column SQL_ID_VC added to WRI$_ADV_OBJECTS.

PRO Seeing an ORA-54013 error is normal due to presence of new column SQL_ID_VC added to WRI\$_ADV_OBJECTS
PRO Attempting inserting rows from backed up table WRI\$_ADV_OBJECTS_NEW to restore the records of the advisor objects again...
INSERT INTO WRI\$_ADV_OBJECTS("ID" ,"TYPE" ,"TASK_ID" ,"EXEC_NAME" ,"ATTR1" ,"ATTR2" ,"ATTR3" ,"ATTR4" ,"ATTR5" ,"ATTR6" ,"ATTR7" ,"ATTR8" ,"ATTR9" ,"ATTR10","ATTR11","ATTR12","ATTR13","ATTR14","ATTR15","ATTR16","ATTR17","ATTR18","ATTR19","ATTR20","OTHER" ,"SPARE_N1" ,"SPARE_N2" ,"SPARE_N3" ,"SPARE_N4" ,"SPARE_C1" ,"SPARE_C2" ,"SPARE_C3" ,"SPARE_C4" ) SELECT "ID" ,"TYPE" ,"TASK_ID" ,"EXEC_NAME" ,"ATTR1" ,"ATTR2" ,"ATTR3" ,"ATTR4" ,"ATTR5" ,"ATTR6" ,"ATTR7" ,"ATTR8" ,"ATTR9" ,
"ATTR10","ATTR11","ATTR12","ATTR13","ATTR14","ATTR15","ATTR16","ATTR17","ATTR18","ATTR19","ATTR20","OTHER" ,"SPARE_N1" , "SPARE_N2" ,"SPARE_N3" ,"SPARE_N4" ,"SPARE_C1" ,"SPARE_C2" ,"SPARE_C3" ,"SPARE_C4" FROM WRI\$_ADV_OBJECTS_NEW;

PRO Committing transaction...
COMMIT;

-- ### Reorganize the indexes ###
PRO Rebuilding WRI\$_ADV_OBJECTS_PK index...
ALTER INDEX WRI\$_ADV_OBJECTS_PK REBUILD;
-- rebuilding the function based indexes won't executed because they need to be dropped and recreated
-- so that the WRI$_ADV_OBJECTS table can be shrunk with row movement enabled
-- ALTER INDEX WRI\$_ADV_OBJECTS_IDX_01 REBUILD;
-- ALTER INDEX WRI\$_ADV_OBJECTS_IDX_02 REBUILD;

-- drop staging table for WRI$_ADV_OBJECTS
PRO Dropping staging table...
DROP TABLE WRI\$_ADV_OBJECTS_NEW;

-- Drop the statistics advisor task from dictionary to refrain from executing.
PRO Dropping AUTO_STATS_ADVISOR_TASK advisor task...
DECLARE
v_tname VARCHAR2(32767);
BEGIN
v_tname := 'AUTO_STATS_ADVISOR_TASK';
DBMS_STATS.DROP_ADVISOR_TASK(v_tname);
END;
/

-- Instead of the drop, we simply disable the AUTO_STATS_ADVISOR_TASK
-- This won't work due to Oracle Support Bug 26749785 (PERF_DIAG: NEED TO HAVE MORE CONTROL IN DICTIONARY FOR AUTO_STATS_ADVISOR_TASK)
-- this command is commented out due to this bug
-- the AUTO_STATS_ADVISOR_TASK is dropped just before this instead
-- EXEC DBMS_STATS.SET_GLOBAL_PREFS('AUTO_STATS_ADVISOR_TASK','FALSE');

-- check for the AUTO_STATS_ADVISOR_TASK being removed; only INDIVIDUAL_STATS_ADVISOR_TASK should remain
select name, ctime, how_created, OWNER_NAME from sys.wri\$_adv_tasks where name in ('AUTO_STATS_ADVISOR_TASK','INDIVIDUAL_STATS_ADVISOR_TASK');

-- drop function based indexes so that the SYS.WRI$_ADV_OBJECTS table high water mark in the SYSAUX tablespace can be reduced
PRO Dropping function based indexes so that the WRI\$_ADV_OBJECTS table can be shrunk...
DROP INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_01";
DROP INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_02";

PRO Enabling row movement...
EXEC DBMS_PDB.EXEC_AS_ORACLE_SCRIPT('ALTER TABLE SYS.WRI\$_ADV_OBJECTS ENABLE ROW MOVEMENT');
PRO Shrinking WRI\$_ADV_OBJECTS table...
EXEC DBMS_PDB.EXEC_AS_ORACLE_SCRIPT('ALTER TABLE SYS.WRI\$_ADV_OBJECTS SHRINK SPACE COMPACT');
PRO Disabling row movement...
EXEC DBMS_PDB.EXEC_AS_ORACLE_SCRIPT('ALTER TABLE SYS.WRI\$_ADV_OBJECTS DISABLE ROW MOVEMENT');

PRO Recreating function based indexes for WRI\$_ADV_OBJECTS table...
CREATE UNIQUE INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_01" ON "SYS"."WRI\$_ADV_OBJECTS" ("TASK_ID", "EXEC_NAME", "ID")
PCTFREE 10 INITRANS 2 MAXTRANS 255 COMPUTE STATISTICS
STORAGE(INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645
PCTINCREASE 0 FREELISTS 1 FREELIST GROUPS 1
BUFFER_POOL DEFAULT FLASH_CACHE DEFAULT CELL_FLASH_CACHE DEFAULT)
TABLESPACE "SYSAUX";

CREATE INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_02" ON "SYS"."WRI\$_ADV_OBJECTS" ("TASK_ID", "EXEC_NAME", "SQL_ID_VC")
PCTFREE 10 INITRANS 2 MAXTRANS 255 COMPUTE STATISTICS
STORAGE(INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645
PCTINCREASE 0 FREELISTS 1 FREELIST GROUPS 1
BUFFER_POOL DEFAULT FLASH_CACHE DEFAULT CELL_FLASH_CACHE DEFAULT)
TABLESPACE "SYSAUX";

show con_name;
PRO TS_NAME,MEGS_ALLOC,MEGS_FREE,MEGS_USED,PCT_FREE,PCT_USED,USED_PCT_OF_MAX,MAX_MB,STATUS,CONTENTS	
select * from ( 
       select ltrim(rtrim(a.tablespace_name)) || ',' ||
       round(a.bytes_alloc / 1024 / 1024) /* megs_alloc */ || ',' ||
       round(nvl(b.bytes_free, 0) / 1024 / 1024) /* megs_free */ || ',' ||
       round((a.bytes_alloc - nvl(b.bytes_free, 0)) / 1024 / 1024) /* megs_used */ || ',' ||
       round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100) /* Pct_Free */ || '%,' ||
       trim(100 - round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100)) /* Pct_used */ || '%,' ||
       round((((a.bytes_alloc - nvl(b.bytes_free, 0))) / round(maxbytes)) * 100) /* USED_PCT_OF_MAX */ || '%,' ||
       round(maxbytes/1048576) || ',' ||
       c.status || ',' ||
       c.contents
from  ( select  f.tablespace_name,
               sum(f.bytes) bytes_alloc,
               sum(decode(f.autoextensible, 'YES',f.maxbytes,'NO', f.bytes)) maxbytes
        from dba_data_files f
        group by tablespace_name) a,
      (
             select ts.name tablespace_name, sum(fs.blocks) * ts.blocksize bytes_free
             from   DBA_LMT_FREE_SPACE fs, sys.ts$ ts
             where  ts.ts# = fs.tablespace_id
             group by ts.name, ts.blocksize
      ) b,
      dba_tablespaces c
where a.tablespace_name = b.tablespace_name (+)
and a.tablespace_name = c.tablespace_name
union all
select ltrim(rtrim(h.tablespace_name)) || ',' ||
       round(sum(h.bytes_free + h.bytes_used) / 1048576) /* megs_alloc */ || ',' ||
       round(sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / 1048576) /* megs_free */ || ',' ||
       round(sum(nvl(p.bytes_used, 0))/ 1048576) /* megs_used */ || ',' ||
       round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100) /* Pct_Free */ || ',' ||
       trim(100 - round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100)) /* pct_used */ || ',' ||
       round(sum(nvl(p.bytes_used, 0)) / round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes))) * 100) /* USED_PCT_OF_MAX */ || ',' ||
       round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes) / 1048576)) /* max */ || ',' ||
       c.status || ',' ||
       c.contents
from   sys.v_\$TEMP_SPACE_HEADER h,
       sys.v_\$Temp_extent_pool p,
       dba_temp_files f,
      dba_tablespaces c
where  p.file_id(+) = h.file_id
and    p.tablespace_name(+) = h.tablespace_name
and    f.file_id = h.file_id
and    f.tablespace_name = h.tablespace_name
and f.tablespace_name = c.tablespace_name
group by h.tablespace_name, c.status, c.contents)
order by 1;

select SYSTIMESTAMP FROM DUAL;

CLEANUP

# deploy_auto_stats_advisor_fix_non_cdb
}

pdb_cleanup_and_disable_auto_stats_advisor () {
# use the first argument to this function as the value for the PDB
PDB_ORACLE_SID=$1

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

if [[ $PDB_OPEN_CHECK = "OPEN" && $PDB_STATE_CHECK = "READ WRITE" ]];then
  # role check for pluggable
  pluggable_role_check
  if [[ $role_check_for_pluggable = 'PHYSICAL STANDBY' ]];then
    usage
    echo "The $specified_pluggable_database database is a PHYSICAL STANDBY and won't have any SQL executed in it."
    exit 1
  fi

  #echo "Checking ${PDB_ORACLE_SID}..."

# cleanup SYS.WRI$_ADV_OBJECTS table and disable AUTO_STATS_ADVISOR_TASK for pdb(s) here

$ORACLE_HOME/bin/sqlplus -S "/ as sysdba" << CLEANUP
set feedback on heading on verify off trim on pages 2000 linesize 200;
alter session set container=$PDB_ORACLE_SID;

show con_name;
select SYSTIMESTAMP FROM DUAL;
PRO TS_NAME,MEGS_ALLOC,MEGS_FREE,MEGS_USED,PCT_FREE,PCT_USED,USED_PCT_OF_MAX,MAX_MB,STATUS,CONTENTS	
select * from ( 
       select ltrim(rtrim(a.tablespace_name)) || ',' ||
       round(a.bytes_alloc / 1024 / 1024) /* megs_alloc */ || ',' ||
       round(nvl(b.bytes_free, 0) / 1024 / 1024) /* megs_free */ || ',' ||
       round((a.bytes_alloc - nvl(b.bytes_free, 0)) / 1024 / 1024) /* megs_used */ || ',' ||
       round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100) /* Pct_Free */ || '%,' ||
       trim(100 - round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100)) /* Pct_used */ || '%,' ||
       round((((a.bytes_alloc - nvl(b.bytes_free, 0))) / round(maxbytes)) * 100) /* USED_PCT_OF_MAX */ || '%,' ||
       round(maxbytes/1048576) || ',' ||
       c.status || ',' ||
       c.contents
from  ( select  f.tablespace_name,
               sum(f.bytes) bytes_alloc,
               sum(decode(f.autoextensible, 'YES',f.maxbytes,'NO', f.bytes)) maxbytes
        from dba_data_files f
        group by tablespace_name) a,
      (
             select ts.name tablespace_name, sum(fs.blocks) * ts.blocksize bytes_free
             from   DBA_LMT_FREE_SPACE fs, sys.ts$ ts
             where  ts.ts# = fs.tablespace_id
             group by ts.name, ts.blocksize
      ) b,
      dba_tablespaces c
where a.tablespace_name = b.tablespace_name (+)
and a.tablespace_name = c.tablespace_name
union all
select ltrim(rtrim(h.tablespace_name)) || ',' ||
       round(sum(h.bytes_free + h.bytes_used) / 1048576) /* megs_alloc */ || ',' ||
       round(sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / 1048576) /* megs_free */ || ',' ||
       round(sum(nvl(p.bytes_used, 0))/ 1048576) /* megs_used */ || ',' ||
       round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100) /* Pct_Free */ || ',' ||
       trim(100 - round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100)) /* pct_used */ || ',' ||
       round(sum(nvl(p.bytes_used, 0)) / round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes))) * 100) /* USED_PCT_OF_MAX */ || ',' ||
       round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes) / 1048576)) /* max */ || ',' ||
       c.status || ',' ||
       c.contents
from   sys.v_\$TEMP_SPACE_HEADER h,
       sys.v_\$Temp_extent_pool p,
       dba_temp_files f,
      dba_tablespaces c
where  p.file_id(+) = h.file_id
and    p.tablespace_name(+) = h.tablespace_name
and    f.file_id = h.file_id
and    f.tablespace_name = h.tablespace_name
and f.tablespace_name = c.tablespace_name
group by h.tablespace_name, c.status, c.contents)
order by 1;

PRO Checking number of rows in WRI\$_ADV_OBJECTS for the AUTO_STATS_ADVISOR_TASK
-- ### Check the no.of rows in WRI$_ADV_OBJECTS for Auto Stats Advisor Task ###
SELECT COUNT(*) FROM WRI\$_ADV_OBJECTS WHERE TASK_ID=(SELECT /*+ no_unnest push_subq */ DISTINCT ID FROM WRI\$_ADV_TASKS WHERE NAME='AUTO_STATS_ADVISOR_TASK');

SELECT SYSTIMESTAMP FROM DUAL;

PRO Creating table WRI\$_ADV_OBJECTS_NEW as SELECT * FROM WRI\$_ADV_OBJECTS...
-- ### Do CTAS from WRI$_ADV_OBJECTS to keep the rows apart from AUTO_STATS_ADVISOR_TASK ###
CREATE TABLE WRI\$_ADV_OBJECTS_NEW AS SELECT * FROM WRI\$_ADV_OBJECTS WHERE TASK_ID !=(SELECT /*+ no_unnest push_subq */ DISTINCT ID FROM WRI\$_ADV_TASKS WHERE NAME='AUTO_STATS_ADVISOR_TASK');

SELECT SYSTIMESTAMP FROM DUAL;

PRO Count of WRI\$_ADV_OBJECTS_NEW
SELECT COUNT(*) FROM WRI\$_ADV_OBJECTS_NEW;

-- ### Truncate the table ###
PRO Truncating WRI\$_ADV_OBJECTS table...
TRUNCATE TABLE WRI\$_ADV_OBJECTS;

-- ### Insert the rows from backed up table WRI$_ADV_OBJECTS_NEW to restore the records of the advisor objects ###
PRO Inserting rows from backed up table WRI\$_ADV_OBJECTS_NEW to restore the records of the advisor objects...
INSERT /*+ APPEND */ INTO WRI\$_ADV_OBJECTS SELECT * FROM WRI\$_ADV_OBJECTS_NEW;
-- For 19c & above, use the below insert statement to avoid ORA-54013 error as there is a new column SQL_ID_VC added to WRI$_ADV_OBJECTS.

PRO Seeing an ORA-54013 error is normal due to presence of new column SQL_ID_VC added to WRI\$_ADV_OBJECTS
PRO Attempting inserting rows from backed up table WRI\$_ADV_OBJECTS_NEW to restore the records of the advisor objects again...
INSERT INTO WRI\$_ADV_OBJECTS("ID" ,"TYPE" ,"TASK_ID" ,"EXEC_NAME" ,"ATTR1" ,"ATTR2" ,"ATTR3" ,"ATTR4" ,"ATTR5" ,"ATTR6" ,"ATTR7" ,"ATTR8" ,"ATTR9" ,"ATTR10","ATTR11","ATTR12","ATTR13","ATTR14","ATTR15","ATTR16","ATTR17","ATTR18","ATTR19","ATTR20","OTHER" ,"SPARE_N1" ,"SPARE_N2" ,"SPARE_N3" ,"SPARE_N4" ,"SPARE_C1" ,"SPARE_C2" ,"SPARE_C3" ,"SPARE_C4" ) SELECT "ID" ,"TYPE" ,"TASK_ID" ,"EXEC_NAME" ,"ATTR1" ,"ATTR2" ,"ATTR3" ,"ATTR4" ,"ATTR5" ,"ATTR6" ,"ATTR7" ,"ATTR8" ,"ATTR9" ,
"ATTR10","ATTR11","ATTR12","ATTR13","ATTR14","ATTR15","ATTR16","ATTR17","ATTR18","ATTR19","ATTR20","OTHER" ,"SPARE_N1" , "SPARE_N2" ,"SPARE_N3" ,"SPARE_N4" ,"SPARE_C1" ,"SPARE_C2" ,"SPARE_C3" ,"SPARE_C4" FROM WRI\$_ADV_OBJECTS_NEW;

PRO Committing transaction...
COMMIT;

-- ### Reorganize the indexes ###
PRO Rebuilding WRI\$_ADV_OBJECTS_PK index...
ALTER INDEX WRI\$_ADV_OBJECTS_PK REBUILD;
-- rebuilding the function based indexes won't executed because they need to be dropped and recreated
-- so that the WRI$_ADV_OBJECTS table can be shrunk with row movement enabled
-- ALTER INDEX WRI\$_ADV_OBJECTS_IDX_01 REBUILD;
-- ALTER INDEX WRI\$_ADV_OBJECTS_IDX_02 REBUILD;

-- drop staging table for WRI$_ADV_OBJECTS
PRO Dropping staging table...
DROP TABLE WRI\$_ADV_OBJECTS_NEW;

-- Drop the statistics advisor task from dictionary to refrain from executing.
PRO Dropping AUTO_STATS_ADVISOR_TASK advisor task...
DECLARE
v_tname VARCHAR2(32767);
BEGIN
v_tname := 'AUTO_STATS_ADVISOR_TASK';
DBMS_STATS.DROP_ADVISOR_TASK(v_tname);
END;
/

-- Instead of the drop, we simply disable the AUTO_STATS_ADVISOR_TASK
-- This won't work due to Oracle Support Bug 26749785 (PERF_DIAG: NEED TO HAVE MORE CONTROL IN DICTIONARY FOR AUTO_STATS_ADVISOR_TASK)
-- this command is commented out due to this bug
-- the AUTO_STATS_ADVISOR_TASK is dropped just before this instead
-- EXEC DBMS_STATS.SET_GLOBAL_PREFS('AUTO_STATS_ADVISOR_TASK','FALSE');

-- check for the AUTO_STATS_ADVISOR_TASK being removed; only INDIVIDUAL_STATS_ADVISOR_TASK should remain
select name, ctime, how_created, OWNER_NAME from sys.wri\$_adv_tasks where name in ('AUTO_STATS_ADVISOR_TASK','INDIVIDUAL_STATS_ADVISOR_TASK');

-- drop function based indexes so that the SYS.WRI$_ADV_OBJECTS table high water mark in the SYSAUX tablespace can be reduced
PRO Dropping function based indexes so that the WRI\$_ADV_OBJECTS table can be shrunk...
DROP INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_01";
DROP INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_02";

PRO Enabling row movement...
EXEC DBMS_PDB.EXEC_AS_ORACLE_SCRIPT('ALTER TABLE SYS.WRI\$_ADV_OBJECTS ENABLE ROW MOVEMENT');
PRO Shrinking WRI\$_ADV_OBJECTS table...
EXEC DBMS_PDB.EXEC_AS_ORACLE_SCRIPT('ALTER TABLE SYS.WRI\$_ADV_OBJECTS SHRINK SPACE COMPACT');
PRO Disabling row movement...
EXEC DBMS_PDB.EXEC_AS_ORACLE_SCRIPT('ALTER TABLE SYS.WRI\$_ADV_OBJECTS DISABLE ROW MOVEMENT');

PRO Recreating function based indexes for WRI\$_ADV_OBJECTS table...
CREATE UNIQUE INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_01" ON "SYS"."WRI\$_ADV_OBJECTS" ("TASK_ID", "EXEC_NAME", "ID")
PCTFREE 10 INITRANS 2 MAXTRANS 255 COMPUTE STATISTICS
STORAGE(INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645
PCTINCREASE 0 FREELISTS 1 FREELIST GROUPS 1
BUFFER_POOL DEFAULT FLASH_CACHE DEFAULT CELL_FLASH_CACHE DEFAULT)
TABLESPACE "SYSAUX";

CREATE INDEX "SYS"."WRI\$_ADV_OBJECTS_IDX_02" ON "SYS"."WRI\$_ADV_OBJECTS" ("TASK_ID", "EXEC_NAME", "SQL_ID_VC")
PCTFREE 10 INITRANS 2 MAXTRANS 255 COMPUTE STATISTICS
STORAGE(INITIAL 65536 NEXT 1048576 MINEXTENTS 1 MAXEXTENTS 2147483645
PCTINCREASE 0 FREELISTS 1 FREELIST GROUPS 1
BUFFER_POOL DEFAULT FLASH_CACHE DEFAULT CELL_FLASH_CACHE DEFAULT)
TABLESPACE "SYSAUX";

show con_name;
PRO TS_NAME,MEGS_ALLOC,MEGS_FREE,MEGS_USED,PCT_FREE,PCT_USED,USED_PCT_OF_MAX,MAX_MB,STATUS,CONTENTS	
select * from ( 
       select ltrim(rtrim(a.tablespace_name)) || ',' ||
       round(a.bytes_alloc / 1024 / 1024) /* megs_alloc */ || ',' ||
       round(nvl(b.bytes_free, 0) / 1024 / 1024) /* megs_free */ || ',' ||
       round((a.bytes_alloc - nvl(b.bytes_free, 0)) / 1024 / 1024) /* megs_used */ || ',' ||
       round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100) /* Pct_Free */ || '%,' ||
       trim(100 - round((nvl(b.bytes_free, 0) / a.bytes_alloc) * 100)) /* Pct_used */ || '%,' ||
       round((((a.bytes_alloc - nvl(b.bytes_free, 0))) / round(maxbytes)) * 100) /* USED_PCT_OF_MAX */ || '%,' ||
       round(maxbytes/1048576) || ',' ||
       c.status || ',' ||
       c.contents
from  ( select  f.tablespace_name,
               sum(f.bytes) bytes_alloc,
               sum(decode(f.autoextensible, 'YES',f.maxbytes,'NO', f.bytes)) maxbytes
        from dba_data_files f
        group by tablespace_name) a,
      (
             select ts.name tablespace_name, sum(fs.blocks) * ts.blocksize bytes_free
             from   DBA_LMT_FREE_SPACE fs, sys.ts$ ts
             where  ts.ts# = fs.tablespace_id
             group by ts.name, ts.blocksize
      ) b,
      dba_tablespaces c
where a.tablespace_name = b.tablespace_name (+)
and a.tablespace_name = c.tablespace_name
union all
select ltrim(rtrim(h.tablespace_name)) || ',' ||
       round(sum(h.bytes_free + h.bytes_used) / 1048576) /* megs_alloc */ || ',' ||
       round(sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / 1048576) /* megs_free */ || ',' ||
       round(sum(nvl(p.bytes_used, 0))/ 1048576) /* megs_used */ || ',' ||
       round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100) /* Pct_Free */ || ',' ||
       trim(100 - round((sum((h.bytes_free + h.bytes_used) - nvl(p.bytes_used, 0)) / sum(h.bytes_used + h.bytes_free)) * 100)) /* pct_used */ || ',' ||
       round(sum(nvl(p.bytes_used, 0)) / round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes))) * 100) /* USED_PCT_OF_MAX */ || ',' ||
       round(sum(decode(f.autoextensible, 'YES', f.maxbytes, 'NO', f.bytes) / 1048576)) /* max */ || ',' ||
       c.status || ',' ||
       c.contents
from   sys.v_\$TEMP_SPACE_HEADER h,
       sys.v_\$Temp_extent_pool p,
       dba_temp_files f,
      dba_tablespaces c
where  p.file_id(+) = h.file_id
and    p.tablespace_name(+) = h.tablespace_name
and    f.file_id = h.file_id
and    f.tablespace_name = h.tablespace_name
and f.tablespace_name = c.tablespace_name
group by h.tablespace_name, c.status, c.contents)
order by 1;

select SYSTIMESTAMP FROM DUAL;

CLEANUP


else
  echo "The $PDB_ORACLE_SID database isn't in an OPEN or MOUNTED state."
  echo "The database is in $PDB_OPEN_CHECK when checking v\$instance"
  echo "The database is in $PDB_STATE_CHECK when checking v\$pdbs"
  echo "Skipping this database..."
# DATABASE_OPEN_CHECK OPEN or MOUNTED
fi

return
# pdb_cleanup_and_disable_auto_stats_advisor
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

# END OF FUNCTIONS


# START MAIN HERE

# if no command line options were used for a specific pluggable database, then use default behavior of checking all pluggable databases on the server
if [[ -n $specified_container_database ]] && [[ -z $specified_pluggable_database ]];then
# default behavior, with no command line options for any specific database, is to cleanup the SYS.WRI$_ADV_OBJECTS table and to remove the AUTO_STATS_ADVISOR_TASK advisor task for all pdbs in the cdb

# iterate through the running pmon processes to extract the ORACLE_SID
# this is somewhat future proof since there is still a running pmon process when running with threaded_execution set to true
# this also defines the Oracle home dynamically, based on the entry in the oratab, making it still function after an upgrade has occurred (if the ORACLE_SID is still the same)
# using ps will only detect container databases; iterating through the pluggable databases within a container isn't done here
  
#  # crosscheck value of ORACLE_SID with oratab entries
#  # only execute if an oratab entry matches a running process
#  # this is done for compatibility for pdb/cdb architecture
#  check_SID_in_oratab=$(cat $ORATAB | grep -v ^'#' | grep "$ORACLE_SID": | cut -d ':' -f 1)
#  if [[ -n $check_SID_in_oratab ]];then
#  
#    if [[ $ostype = "SunOS" ]]; then
#      PMON_FOR_ORACLE_SID=$(ps -ef -o pid,args | grep pmon | grep -w $ORACLE_SID | grep -v grep)
#      PID_OF_PMON=$(echo $PMON_FOR_ORACLE_SID | awk '{print $1}')
#      pargs -e $PID_OF_PMON
#      CHECK_PARGS_EXIT_CODE=$?
#      if [[ $CHECK_PARGS_EXIT_CODE != "0" ]];then
#        echo "The pargs exit code was not zero."
#        echo "The $ORACLE_SID pmon process doesn't belong to this server."
#        echo "Skipping cleanup for the SYS.WRI$_ADV_OBJECTS table and removal of the AUTO_STATS_ADVISOR_TASK advisor task for database: $ORACLE_SID."
#        # reset this loop if the pmon process isn't on this server; the check with pargs reveals this
#        continue
#      fi
#    fi

set_environment $specified_container_database
check_for_binary awk
check_for_binary cut
check_for_binary date
check_for_binary grep
check_for_binary mailx
check_for_binary ps
check_for_binary sed
check_for_binary whoami
sqlplus_is_present_check
check_for_OS_authentication
database_open_check

if [[ ${DATABASE_OPEN_CHECK} = "OPEN" ]] || [[ ${DATABASE_OPEN_CHECK} = "MOUNTED" ]]; then

database_role_check

if [[ ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY" ]]; then
  echo "The $ORACLE_SID database is a PHYSICAL STANDBY and won't have any SQL executed in it."
  continue
else
  # check to see if pluggable database is being used
  # value will be YES if a pdb is used
  # value will be NO if it is a regular database
PDB_DATABASE_CHECK=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << PDBCHK
set feedback off heading off verify off trim on pages 0;
select CDB from v\\$database;
PDBCHK
`

if [[ $PDB_DATABASE_CHECK = "YES" ]]; then
  echo "Container/pluggable database architecture detected.";sleep 1
  
  #load variable with all PDB values
PDB_LIST=`$ORACLE_HOME/bin/sqlplus -s "/ as sysdba" << LISTPDB
set feedback off heading off verify off trim on pages 0;
select name from v\\$pdbs where name != 'PDB\\$SEED' order by name;
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
    # check the container first
    # deploy_auto_stats_advisor_fix_non_cdb
    # check all PDBs in the container, cleanup all SYS.WRI$_ADV_OBJECTS table(s) and remove the AUTO_STATS_ADVISOR_TASK advisor task in all PDBs in this loop
	echo ""
	echo ""
    echo "Cleaning up the SYS.WRI\$_ADV_OBJECTS table and removing the AUTO_STATS_ADVISOR_TASK advisor task in pluggable database: $pdb_to_check"
    pdb_cleanup_and_disable_auto_stats_advisor $pdb_to_check
  done
else
  echo "Traditional Oracle database architecture detected.";sleep 1
  echo "Deploying the cleanup for the SYS.WRI\$_ADV_OBJECTS table and removing the AUTO_STATS_ADVISOR_TASK advisor task for the non-CDB ${ORACLE_SID}"
  deploy_auto_stats_advisor_fix_non_cdb
fi

# ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY"
fi

else
  echo "The $ORACLE_SID database isn't in an OPEN state."
  echo "Skipping this database..."
# DATABASE_OPEN_CHECK OPEN or MOUNTED
fi

# -n $specified_container_database && -z $specified_pluggable_database
else

  echo "Command line settings for a specific pluggable database have been specified."
  if [[ -n $specified_container_database ]] && [[ -n $specified_pluggable_database ]]; then
    echo "Attempting to deploy the cleanup for the SYS.WRI\$_ADV_OBJECTS table and removal of the AUTO_STATS_ADVISOR_TASK advisor task to the $specified_pluggable_database pdb..."
    # check for container database in running processes
    #check_specified_container_present_in_running_processes
    set_environment $specified_container_database
    check_for_binary awk
    check_for_binary cut
    check_for_binary date
    check_for_binary grep
    check_for_binary mailx
    check_for_binary ps
    check_for_binary sed
    check_for_binary whoami
    sqlplus_is_present_check
    check_for_OS_authentication
    database_open_check

    if [[ ${DATABASE_OPEN_CHECK} = "OPEN" ]] || [[ ${DATABASE_OPEN_CHECK} = "MOUNTED" ]]; then
      database_role_check
      if [[ ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY" ]]; then
        usage
        echo "The $ORACLE_SID database is a PHYSICAL STANDBY and won't have any SQL executed in it."
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

    #typeset -i byhourcnt
    #typeset -i byminutecnt
    ## start running this job at 04:00 a.m. for the first pdb sorted alphabetically ascending as seen in v$pdbs
    #byhourcnt=4
    #byminutecnt=0

    echo "Deploying cleanup for the SYS.WRI\$_ADV_OBJECTS table and removal of the AUTO_STATS_ADVISOR_TASK advisor task for pluggable database: $specified_pluggable_database"
    pdb_cleanup_and_disable_auto_stats_advisor $specified_pluggable_database
  
  ## -n $specified_container_database -n $specified_pluggable_database
  #else
  #  
  #  echo "Checking specified single instance/container database."
  #  # check for container database in running processes
  #  check_specified_container_present_in_running_processes
  #  set_environment $specified_container_database
  #  check_for_binary awk
  #  check_for_binary cut
  #  check_for_binary date
  #  check_for_binary grep
  #  check_for_binary mailx
  #  check_for_binary ps
  #  check_for_binary sed
  #  check_for_binary whoami
  #  sqlplus_is_present_check
  #  check_for_OS_authentication
  #  database_open_check
  #
  #  if [[ ${DATABASE_OPEN_CHECK} = "OPEN" ]] || [[ ${DATABASE_OPEN_CHECK} = "MOUNTED" ]]; then
  #    database_role_check
  #    if [[ ${DATABASE_ROLE_CHECK} = "PHYSICAL STANDBY" ]]; then
  #      usage
  #      echo "The $ORACLE_SID database is a PHYSICAL STANDBY and won't have any SQL executed in it."
  #      exit 1
  #    else
  #      # echo "Checking container or single instance database."
  #      deploy_auto_stats_advisor_fix_non_cdb
  #    fi
  #  else
  #    usage
  #    echo "The $ORACLE_SID database isn't in an OPEN state."
  #    exit 1
  #  fi
  
  # -n $specified_container_database && -n $specified_pluggable_database
  fi
  
# -n $specified_container_database && -z $specified_pluggable_database
fi

exit 0
