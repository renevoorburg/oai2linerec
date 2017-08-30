#!/bin/bash

# A simple OAI-PMH harvester. Harvests records, aggregates them to one file, one line per record.
# Requires perl, wget and xmllint (version 20708 or higher).
# @author: René Voorburg / rene.voorburg@kb.nl
# @version: 2017-08-29

# 2017-08-15: Added gzip compression.
# 2017-08-22: Refactored to use retry-function for robustness, no more temporary files.
# 2017-08-25: Fixed incorrect testing for failed actions, added 'verbose' and 'debug' options.
# 2017-08-28: New: harvest may now be paused and resumed. 
# 2017-08-29: New: log slow actions when in debug mode.


# declare global vars:
CMD=$0
IDENTIFIERS_XP="//*[local-name()='header'][not(contains(@status, 'deleted'))]/*[local-name()='identifier']"
RESUMPTION_XP="//*[local-name()='resumptionToken']/text()"
METADATA_XP="//*[local-name()='metadata']"
OUT=''
FROM=''
UNTIL=''
BASE=''
SET=''
PREFIX=''
URL=''
IDENTIFIERS=''
RESUMPTIONTOKEN=''
GZIP=cat
COMPRESS=false
VERBOSE=false
DEBUG=false
RESUMEPARAMS=''
LOGSLOW=10


usage()
{
    cat << EOF
usage: $0 [OPTIONS] -o [outfile] -b [baseURL]

This is a simple OAI-PMH harvester. It harvests records, compresses the <metadata> node and its content to a single line
and appends it to the outfile.

The harvesting process can be paused by pressing 'p'. Restart harvest by supplying a resumptiontoken using '-r'.

Requires perl, wget and xmllint (version 20708 or better, part of the libxml2-utils package) to be able to run.

OPTIONS:
   -h          Show this message
   -v          Verbose, shows progress
   -d          Debug mode, shows retries and slow requests
   -c          Compress output
   -s  set     Specify a set to be harvested
   -p  prefix  Choose which metadata format ('metadataPrefix') to harvest
   -o  out     Define the output file records will be append to
   -f  date    Define a 'from' date.
   -t  date    Define an 'until' date
   -r  token   Provide a resumptiontoken to continue a harvest

EXAMPLE:
$CMD -v -c -s sgd:register -p dcx -f 2012-02-03T09:04:21Z -o results.txt -b http://services.kb.nl/mdo/oai

EOF
}

progress()
{
    local out="$1"

    if [ "$VERBOSE" == "true" ] ; then
        echo -en "$out"
    fi
}

fail()
{
    local msg="$1"

    echo $msg >&2
    if [[ $msg == fatal* ]] || [[ $msg == Fatal* ]] ; then
        exit 1
    else
        return 1
    fi
}

retry() 
{
    local msg="$1"
    local cmd="${@: 2}"
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
                fail "Warning: retried action '$cmd'"
            fi 
        else
            fail $msg
        fi
        }
    done
    
    if [ "$DEBUG" == "true" ] ; then
    	local tend=`date "+%s"`
    	local tspend=$(($tend-$tstart))
    	if  [ "$tspend" -ge "$LOGSLOW" ] ; then
    		fail "Warning: slow ($tspend s) action '$cmd'"
    	fi
    fi
    
}

harvest_record()
{
    local id="$1"
    local metadata="`$GET "$BASE?verb=GetRecord$PREFIX&identifier=$id" | xmllint --xpath "//*[local-name()='metadata']" - 2>/dev/null || return 1`" 

    echo "$metadata" | xmllint --format - | perl -pe 's@\n@@gi' | perl -pe 's@$@\n@' | $GZIP >> $OUT    
    progress "."
}

harvest_identifiers()
{
    local url="$1"
    local identifiers_xml="`$GET "$url" || return 1`"
    local identifiers_selected="`echo "$identifiers_xml" | xmllint --xpath "$IDENTIFIERS_XP" - 2>/dev/null || return 1`"
 
    IDENTIFIERS="`echo "$identifiers_selected" | perl -pe 's@</identifier[^\S\n]*>@\n@g' | perl -pe 's@<identifier[^\S\n]*>@@'`" 
    RESUMPTIONTOKEN="`echo "$identifiers_xml" | xmllint --xpath "$RESUMPTION_XP" - 2>/dev/null || return 1`"
    URL="$BASE?verb=ListIdentifiers&resumptionToken=$RESUMPTIONTOKEN"
}


# check for required environment:
if ! hash perl 2>/dev/null; then
    echo "Requires perl. Not found. Exiting."
    exit
fi
if hash curl 2>/dev/null; then
        GET='curl -s'
elif hash wget  2>/dev/null; then
        GET='wget -q -t 3 -O -'
else
    echo "Requires curl or wget. Not found. Exiting."
    exit
fi
if ! hash xmllint 2>/dev/null; then
    echo "Requires xmllint. Not found. Exiting."
    exit
fi

# read commandline opions
while getopts "hvdco:f:t:b:s:p:r:" OPTION ; do
     case $OPTION in
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
export XMLLINT_INDENT='' #use this setting for single line XML normalization

#
if [ -z "$RESUMPTIONTOKEN" ] ; then
    RESUMPTIONTOKEN='dummy'
    URL="$BASE?verb=ListIdentifiers$FROM$UNTIL$PREFIX$SET"
    >$OUT
else
   progress "Continuing harvest with resumptiontoken $RESUMPTIONTOKEN\n"
   URL="$BASE?verb=ListIdentifiers&resumptionToken=$RESUMPTIONTOKEN"
fi

# main loop:
while [ -n "$RESUMPTIONTOKEN" ] ; do

	# allow keypress 'p' to pause harvesting:
    if [ -n "$IDENTIFIERS" ] ; then
        echo -en "[ Press p to pauze harvest ]"
        read -t 2 -n 1 key && [[ $key = p ]] && echo -e "\nHarvest paused.\nContinue harvest with $CMD -r '$RESUMPTIONTOKEN'$RESUMEPARAMS" && exit 1
        echo -en "\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b"
        echo -en "                            "
        echo -en "\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b"
    fi

	# harvest: 
    retry "Fatal error obtaining identifiers from $URL" harvest_identifiers "$URL"
    for i in `echo "$IDENTIFIERS" ` ; do
        retry "Error harvesting record $i" harvest_record "$i"
    done
    progress "\n$RESUMPTIONTOKEN\n"
done

progress "done\n"
exit 0
