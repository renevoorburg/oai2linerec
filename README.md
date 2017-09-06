# oai2linerec
Unix shell script for harvesting metadata records from OAI-PMH repositories. Runs on macOS and Unix / Linux.

Records are aggregated in a single file, serialized to a single record per line. Optionally, individual records can be compressed to save space.

Use git to clone the data 

```
$ git clone https://github.com/renevoorburg/oai2linerec.git
```

or simply download the `oai2linerec.sh` source and make it executable using `$ chmod +x oai2linerec.sh`.

Invoking it is as easy as

```
$ oai2linerec.sh -s set -p dc -f 2012-02-03 -o results.txt -b http://base.nl/oai
```

Enable logging like this

```
$ oai2linerec.sh -d -s set -p dc -f 2012-02-03 -o results.txt -b http://base.nl/oai 2>harvest.log
```

For an example of how to process such a single linerec output file, see companion script parselinerec.sh. Gzipped output files are fast and easy to use when indexed using [Matt Godbolt's zindex](https://github.com/mattgodbolt/zindex). For parallel processing of linecrec file with shell scripts see [A beginners guide to processing 'lots of' data](http://datatopia.blogspot.nl/2015/10/a-beginners-guide-to-processing-lots-of.html).
