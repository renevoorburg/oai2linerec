#!/bin/bash

# A simple OAI-PMH harvester. Harvests records, aggregates them to one file, one line per record.
# Requires perl, wget and xmllint (version 20708 or higher).
# @author: René Voorburg / rene.voorburg@kb.nl
# @version: 2015-09-17

usage()
{
cat << EOF
usage: $0 [OPTIONS] -o [outfile] -b [baseURL]

This is a simple OAI-PMH harvester. It harvests records, compresses the <metadata> node and its content to a single line
and appends it to the outfile.
Requires perl, wget and xmllint (version 20708 or better, part of the libxml2-utils package) to be able to run.

OPTIONS:
   -h      Show this message
   -s	   Specify a set to be harvested
   -p	   Choose which metadata format ('metadataPrefix') to harvest 
   -o      Define the output file records will be append to
   -f      Define a 'from' date.
   -t      Define an 'until' date

EXAMPLE:
$0 -s sgd:register -p dcx -f 2012-01-20 -o results.txt -b http://services.kb.nl/mdo/oai

EOF
}

harvest()
{
    wget -q -t 3 -O - "$BASE?verb=GetRecord$PREFIX&identifier=$1" | xmllint --xpath "//*[local-name()='metadata']" - | xmllint --format - | perl -pe 's@\n@@gi' >> $OUT
    echo >> $OUT
    echo -n "."
}

# initialize vars:
IDENTIFIERS_XP="//*[local-name()='header'][not(contains(@status, 'deleted'))]/*[local-name()='identifier']"
RESUMPTION_XP="//*[local-name()='resumptionToken']/text()"
METADATA_XP="//*[local-name()='metadata']"
OUT=''
FROM=''
UNTIL=''
BASE=''
SET=''
PREFIX=''
TMPFILE="tmp$$.xml"

# read commandline opions
while getopts "ho:f:t:b:s:p:" OPTION ; do
     case $OPTION in
         h)
             usage
             exit 1
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

# do have the required info?:
if [ -z "$BASE" ] ; then
	usage
	exit
fi
if [ -z "$OUT" ] ; then
	usage
	exit
fi



# now we should be able to go harvesting:
export XMLLINT_INDENT=''

## set initial vars for first harvest-iteration:
resumptiontoken="dummy"
url="$BASE?verb=ListIdentifiers$FROM$UNTIL$PREFIX$SET"

# harvest all identifiers and create a directory for each one
while [ -n "$resumptiontoken" ] ; do
    # harvest block of oai-identifiers
    wget -q -t 3 -O - "$url" > $TMPFILE

    # prepare url for harvest of next block
    resumptiontoken=`xmllint --xpath "$RESUMPTION_XP" $TMPFILE`
    url="$BASE?verb=ListIdentifiers&resumptionToken=$resumptiontoken"

    # show progress:
    echo
    echo $resumptiontoken

    # extract oai-identifiers and harvest each one of them:
    for i in `xmllint --xpath "$IDENTIFIERS_XP" $TMPFILE | perl -pe 's@</identifier[^\S\n]*>@\n@g' | perl -pe 's@<identifier[^\S\n]*>@@'` ; do
        harvest $i
    done

done
rm $TMPFILE

echo "done"

