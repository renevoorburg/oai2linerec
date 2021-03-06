#!/bin/bash

# A Unix shell script for harvesting metadata records from OAI-PMH repositories. Tested on macOS and Unix / Linux.
# Records are aggregated in a single file, serialized to a single record per line.
# Optionally, individual records can be compressed to save space.

# Requires perl, wget or curl and xmllint (version 20708 or higher).
# @author: René Voorburg / rene.voorburg@kb.nl
# @version: 2.2 dd 2017-09-22

# 2017-09-01: The 'retries now actually works' version with improved logging, cleaner code.
# 2017-09-05: Urlencodes identifiers.
# 2017-09-11: Fixes issue #2; harvesting should not stop when no ids found but resumption token is available.
# 2017-09-19: Adds an option to harvest using a list of identifiers.
# 2017-09-22: Allows users to circumvent serialization to a single line. Best in combination with compressed records.

# we need this:
set +H

## declare global vars:

# defaults:
LOGSLOW=10
CURL='curl -fs'
WGET='wget -q -t 3 -O -'
COMPRESS=false
VERBOSE=false
DEBUG=false
GZIP=cat
POSTPROCESS="perl -p00e 's@\n(?!\Z)@ @g'"

# no need to change these:
PROG=$0
IDENTIFIERS_XP="//*[local-name()='header'][not(contains(@status, 'deleted'))]/*[local-name()='identifier']"
RESUMPTION_XP="//*[local-name()='resumptionToken']/text()"
METADATA_XP="//*[local-name()='metadata']"

# init other globals:
OUT=''
FROM=''
UNTIL=''
BASE=''
SET=''
PREFIX=''
URL=''
IDENTIFIERS=''
RESUMPTIONTOKEN=''
RESUMEPARAMS=''
IDSFILE=''

#required for single line XML normalization:
export XMLLINT_INDENT=''


usage()
{
    cat << EOF
usage: $PROG [OPTIONS] -o [outfile] -b [baseURL]

This is a simple OAI-PMH harvester. It harvests records, compresses the <metadata> node and its content to a single line
and appends it to the outfile.

The harvesting process can be paused by pressing 'p'. Restart harvest by supplying a resumptiontoken using '-r'.

Requires perl, wget and xmllint (version 20708 or better, part of the libxml2-utils package) to be able to run.

OPTIONS:
   -h          Show this message
   -v          Verbose, shows progress
   -d          Debug mode, shows retries and slow requests
   -c          Compress output
   -n          Do not serialize records to a single line.
   -s  set     Specify a set to be harvested
   -p  prefix  Choose which metadata format ('metadataPrefix') to harvest
   -o  out     Define the output file records will be append to
   -f  date    Define a 'from' date.
   -t  date    Define an 'until' date
   -r  token   Provide a resumptiontoken to continue a harvest
   -i  idfile  Provide a list of identifiers to harvest.

EXAMPLE:
$PROG -v -c -s sgd:register -p dcx -f 2012-02-03T09:04:23Z -o results.txt -b http://services.kb.nl/mdo/oai

EOF
}

show_progress()
{
    local out="$1"

    if [ "$VERBOSE" == "true" ] ; then
        echo -en "$out"
    fi
}

log()
{
    local msg="$@"
    local date=`date "+%Y-%m-%d %H:%M:%S"`

    echo "$date $msg" >&2
}

retry()
{
    local cmd="$@"
    local ret=0
    local n=1
    local max=3
    local delay=3
    local tstart=`date "+%s"`

    while true; do
        $cmd && break || {
    		if [[ $n -lt $max ]]; then
            	((n++))
            	sleep $delay;
            	if [ "$DEBUG" == "true" ] ; then
                	log "Warning: '$cmd' failed, retrying."
            	fi
        	else
            	log "Error: '$cmd' failed after retry $max."
            	ret=1
            	break
        	fi
        }
    done

    if [ "$DEBUG" == "true" ] ; then
    	local tend=`date "+%s"`
    	local tspend=$(($tend-$tstart))
    	if  [ "$tspend" -ge "$LOGSLOW" ] ; then
    		log "Warning: '$cmd' slow ($tspend s)."
    	fi
    fi

    return $ret
}

rawurlencode()
{
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * )               printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done
  echo "${encoded}"
}

harvest_record()
{
    local id=$(rawurlencode "$1")
    local metadata
    local payload

    metadata="`$GET "$BASE?verb=GetRecord$PREFIX&identifier=$id" | xmllint --xpath "//*[local-name()='metadata']" - 2>/dev/null`"
    if [ $? -ne 0 ] ; then return 1 ; fi

    payload="`echo "$metadata" | xmllint --format - 2>/dev/null`" 
    if [ $? -ne 0 ] ; then return 1 ; fi

    echo "$payload" | eval "$POSTPROCESS" | $GZIP >> $OUT
    show_progress "."
}

harvest_identifiers()
{
    local url="$1"
    local identifiers_xml
    local identifiers_selected
    local ret_ids_found
    local ret_resumption_found

    identifiers_xml="`$GET "$url"`"
    if [ $? -ne 0 ] ; then return 1 ; fi

    identifiers_selected="`echo "$identifiers_xml" | xmllint --xpath "$IDENTIFIERS_XP" - 2>/dev/null`"
    ret_ids_found=$?
    RESUMPTIONTOKEN="`echo "$identifiers_xml" | xmllint --xpath "$RESUMPTION_XP" - 2>/dev/null`"
    ret_resumption_found=$?
    if [ $ret_ids_found -ne 0 ] && [ $ret_resumption_found -ne 0 ] ; then return 1 ; fi

    IDENTIFIERS="`echo "$identifiers_selected" | perl -pe 's@</identifier[^\S\n]*>@\n@g' | perl -pe 's@<identifier[^\S\n]*>@@'`"
    URL="$BASE?verb=ListIdentifiers&resumptionToken=$RESUMPTIONTOKEN"
}


get_parameters()
{
	local option

	# check for required environment:
	if ! hash perl 2>/dev/null; then
		echo "Requires perl. Not found. Exiting."
		exit 1
	fi
	if hash curl 2>/dev/null; then
			GET="$CURL"
	elif hash wget  2>/dev/null; then
			GET="$WGET"
	else
		echo "Requires curl or wget. Not found. Exiting."
		exit 1
	fi
	if ! hash xmllint 2>/dev/null; then
		echo "Requires xmllint. Not found. Exiting."
		exit 1
	fi

	# read commandline opions
	while getopts "hvdcno:f:t:b:s:p:r:i:" option ; do
		 case $option in
			 h)
				 usage
				 exit 1
				 ;;
			 v)  VERBOSE=true
				 RESUMEPARAMS="$RESUMEPARAMS -v"
				 ;;
			 d)  DEBUG=true
				 RESUMEPARAMS="$RESUMEPARAMS -d"
				 ;;
			 c)  COMPRESS=true
				 RESUMEPARAMS="$RESUMEPARAMS -c"
				 ;;
		     n)  POSTPROCESS=cat
		         ;;	
			 o)
				 OUT="$OPTARG"
				 RESUMEPARAMS="$RESUMEPARAMS -o $OPTARG"
				 ;;
			 f)
				 FROM="&from=$OPTARG"
				 ;;
			 t)
				 UNTIL="&until=$OPTARG"
				 ;;
			 s)
				 SET="&set=$OPTARG"
				 ;;
			 b)
				 BASE="$OPTARG"
				 RESUMEPARAMS="$RESUMEPARAMS -b $OPTARG"
				 ;;
			 p)
				 PREFIX="&metadataPrefix=$OPTARG"
				 RESUMEPARAMS="$RESUMEPARAMS -p $OPTARG"
				 ;;
			 r)
				 RESUMPTIONTOKEN="$OPTARG"
				 ;;
			 i)	 IDSFILE="$OPTARG"
				 ;;
			 ?)
				 usage
				 exit
				 ;;
		 esac
	done

	# set and test parameters:
	if [ -z "$BASE" ] ; then
		usage
		exit 1
	fi
	if [ -z "$OUT" ] ; then
		usage
		exit 1
	fi

	if [ "$COMPRESS" == "true" ] ; then
		if ! hash gzip 2>/dev/null; then
			echo "Compression requires gzip. Not found. Exiting."
			exit 1
		fi
		GZIP=gzip
	 	OUT=$OUT.gz
	fi

	#
	if [ -n "$RESUMPTIONTOKEN" ] ; then
		URL="$BASE?verb=ListIdentifiers&resumptionToken=$RESUMPTIONTOKEN"
	elif [ -n "$IDSFILE" ] ; then
		if [ ! -e "$IDSFILE" ] ; then
			echo "File $IDSFILE (containing identifiers) not found. Exiting."
			exit 1
		fi
		RESUMPTIONTOKEN='dummy'
	else
		RESUMPTIONTOKEN='dummy'
		URL="$BASE?verb=ListIdentifiers$FROM$UNTIL$PREFIX$SET"
		>$OUT
	fi

}

exit_keypress()
{
	local listen="$1"
	local msg="$2"
	local alert="$3"

	echo -en "$msg"
	read -t 2 -n 1 key && [[ $key = "$listen" ]] && echo -e "\n$alert" && exit 1
	printf '\b%.0s' {1..100}
	printf ' %.0s' {1..100}
	printf '\b%.0s' {1..100}
}

main()
{
	local id

	while [ -n "$RESUMPTIONTOKEN" ] ; do

		# allow keypress 'p' to pause harvesting:
		if [ -n "$IDENTIFIERS" ] ; then
			exit_keypress "p" "[ Press p to pauze harvest ]" "\nHarvest paused.\nContinue harvest with $PROG -r '$RESUMPTIONTOKEN'$RESUMEPARAMS"
		fi

		# get identifiers:
		if [ -z "$IDSFILE" ] ; then
			retry harvest_identifiers "$URL"
			if [ $? -ne 0 ] ; then exit 1 ; fi
		else
			IDENTIFIERS="`cat $IDSFILE`"
			RESUMPTIONTOKEN=""
		fi

		for id in `echo "$IDENTIFIERS" ` ; do
			retry harvest_record "$id"
		done
		show_progress "\n$RESUMPTIONTOKEN\n"
	done

	show_progress "done\n"
}


get_parameters "$@"
main
exit 0
