#!/bin/bash

# An example of how to parse linerec files as created by oai2linerec. 
# @author: René Voorburg / rene.voorburg@kb.nl
# @version: 2015-09-18


if [ ! -f "$1" ] ; then
    echo "Error: no file given to process or file not found. "
    echo 
    echo "Usage: $0 [linerecfile]"
    echo
    echo "This is just an example of how to process data in linerec files as created by oai2linerec"
    exit
fi


# use only newlines as IFS, store prev. IFS:
storedIFS=$IFS
export IFS=$'\n'

for line in `cat $1` ; do
    # this example just sends the record to xmllint to present is nicely formatted:
    echo $line | xmllint --format -
done

export IFS=$storedIFS
