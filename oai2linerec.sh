#!/bin/bash

# A simple OAI-PMH harvester. Harvests records, aggregates them to one file, one line per record.
# Requires perl, wget and xmllint (version 20708 or higher).
# @author: René Voorburg / rene.voorburg@kb.nl
# @version: 2017-08-25

# 2017-08-15: Added gzip compression.
# 2017-08-22: Refactored to use retry-function for robustness, no more temporary files.
# 2017-08-25: Fixed incorrect testing for failed actions, added 'verbose' and 'debug' options.


usage()
{
    cat << EOF
usage: $0 [OPTIONS] -o [outfile] -b [baseURL]

This is a simple OAI-PMH harvester. It harvests records, compresses the <metadata> node and its content to a single line
and appends it to the outfile.
Requires perl, wget and xmllint (version 20708 or better, part of the libxml2-utils package) to be able to run.

OPTIONS:
   -h      Show this message
   -v      Verbose, shows progress
   -d      Debug mode, shows retries
   -c      Compress output
   -s      Specify a set to be harvested
   -p      Choose which metadata format ('metadataPrefix') to harvest
   -o      Define the output file records will be append to
   -f      Define a 'from' date.
   -t      Define an 'until' date

EXAMPLE:
$0 -v -c -s sgd:register -p dcx -f 2012-02-03T09:04:21Z -o results.txt -b http://services.kb.nl/mdo/oai

EOF
}

progress()
{
    local out=$1

    if [ "$VERBOSE" == "true" ] ; then
        echo -en "$out"
    fi
}

fail()
{
    local msg=$1

    echo $msg >&2
    if [[ $msg == fatal* ]] || [[ $msg == Fatal* ]] ; then
        exit 1
    else
        return 1
    fi
}

retry() 
{
    local msg=$1
    local cmd="${@: 2}"
    local n=1
    local max=3
    local delay=3

    while true; do
        $cmd && break || {
        if [[ $n -lt $max ]]; then
            ((n++))
            sleep $delay;
            if [ "$DEBUG" == "true" ] ; then
                echo "Retry:" $msg
            fi 
        else
            fail $msg
        fi
        }
    done
}

harvest_record()
{
    local id=$1
    local metadata="`$GET "$BASE?verb=GetRecord$PREFIX&identifier=$id" | xmllint --xpath "//*[local-name()='metadata']" - 2>/dev/null || return 1`" 

    echo "$metadata" | xmllint --format - | perl -pe 's@\n@@gi' | perl -pe 's@$@\n@' | $GZIP >> $OUT    
    progress "."
}

harvest_identifiers()
{
    local url=$1
    local identifiers_xml="`$GET "$url" || return 1`"
    local identifiers_selected="`echo "$identifiers_xml" | xmllint --xpath "$IDENTIFIERS_XP" - 2>/dev/null || return 1`"
 
    IDENTIFIERS="`echo "$identifiers_selected" | perl -pe 's@</identifier[^\S\n]*>@\n@g' | perl -pe 's@<identifier[^\S\n]*>@@'`" 
    RESUMPTIONTOKEN="`echo "$identifiers_xml" | xmllint --xpath "$RESUMPTION_XP" - 2>/dev/null || return 1`"
    URL="$BASE?verb=ListIdentifiers&resumptionToken=$RESUMPTIONTOKEN"
}

# test basic requirements:
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

# declare global vars:
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
RESUMPTIONTOKEN='dummy'
GZIP=cat
COMPRESS=false
VERBOSE=false
DEBUG=false

# read commandline opions
while getopts "hvdco:f:t:b:s:p:" OPTION ; do
     case $OPTION in
         h)
             usage
             exit 1
             ;;
         v)  VERBOSE=true
             ;;
         d)  DEBUG=true
             ;;
         c)  COMPRESS=true
             ;;
         o)
             OUT="$OPTARG"
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
             ;;
         p)
             PREFIX="&metadataPrefix=$OPTARG"
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
>$OUT
export XMLLINT_INDENT='' #use this setting for single line XML normalization

# main harvest loop:
URL="$BASE?verb=ListIdentifiers$FROM$UNTIL$PREFIX$SET" 
while [ -n "$RESUMPTIONTOKEN" ] ; do
    retry "Fatal error obtaining identifiers from $URL" harvest_identifiers $URL
    for i in `echo "$IDENTIFIERS" ` ; do
        retry "Error harvesting record $i" harvest_record $i
    done
    progress "\n$RESUMPTIONTOKEN\n\n"
done

progress "done\n"
exit 0
