#!/bin/bash

if [ -z "$FILE_EXCLUDE_PATHS" ]; then
    FILE_EXCLUDE_PATHS=""
fi

if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH="master"
fi

set -eu -o pipefail

#TODO: handle having pv or not
#TODO: handle having ag or not

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# go from git checkout to fixed-size feature for downstream model training
# on the way produce an inventory and description of all lines and diffs

FILE_FILESTATUS=${DATADIR}/filestatus
FILE_FILELIST=${DATADIR}/files
FILE_COMMIT_DATES=${DATADIR}/commitdates
FILE_COMMITS=${DATADIR}/commits
FILE_LINES=${DATADIR}/lines.gz
FILE_LINELOG=${DATADIR}/linelog.gz
FILE_CODEFILE=${DATADIR}/codefile
FILE_ADDFILE=${DATADIR}/addfile
FILE_REMFILE=${DATADIR}/remfile
FILE_BINARIESFILE=${DATADIR}/binariesfile
FILE_METADATA=${DATADIR}/metadata.gz


# assume we're in a git checkout
# analyze history and commits to pull out diffs and lines of code
# prepare diff and line data (these are important intermediate outputs)
# embed those lines of code into some vector space
# prepare fixed length feature file (e.g. for training and analysis)


# choose the commits you're going to look at (git log)
# get all the filestatuses for relevant changes
echo "listing commits on $DEFAULT_BRANCH to ${FILE_FILESTATUS}"
git log --no-renames -m --first-parent --name-status --topo-order --format='%H%x09%ct%x09%P' $DEFAULT_BRANCH | gawk 'BEGIN {OFS="\t"} NR == 1 {next_master=$1;last_master=$1} next_master != "" && $1 == next_master { next_master = $3; last_master=$1} $1 ~ /^[a-f0-9]{40}$/ {last_commit = $1} NF > 0 && $1 !~ /^[a-f0-9]{40}$/ { print last_master, last_commit, $0}' | pv > ${FILE_FILESTATUS}

#exclude external files and documentation
echo "filtering external/3rd party files and documentation..."
if [ -z "$FILE_EXCLUDE_PATHS" ]; then
    cat ${FILE_FILESTATUS} | cut -f 4 | LC_ALL=C sort -u > ${FILE_FILELIST}
else
    cat <(cat ${FILE_FILESTATUS} | cut -f 4) <(cat ${FILE_FILESTATUS} | cut -f5) |\
        LC_ALL=C sort -u |\
        gawk 'BEGIN {n=0} FNR==NR {excluderegex = $0} FNR!=NR { if($1 !~ excluderegex) {print $1}}' <(cat ${FILE_EXCLUDE_PATHS} | tr '\n' '|' | sed 's/|$//') - | grep -v '^$' > ${FILE_FILELIST} || true
fi

echo "checking if any files remain..."
if [ ! -s "${FILE_FILELIST}" ]; then
    echo "after dropping excluded files, nothing left to analyze"
    unique_files=$(cat <(cat ${FILE_FILESTATUS} | cut -f 4) <(cat ${FILE_FILESTATUS} | cut -f 5) | sort -u | wc -l)
    echo "${unique_files} unique files before filtering"
    exit 1
fi

#get some metadata
echo "getting commit dates..."
git log --no-renames --first-parent --topo-order --format='%H%x09%ct%x09%P%x09%t%x09%s' $DEFAULT_BRANCH | cut -f 1,2 | LC_ALL=C sort -u > ${FILE_COMMIT_DATES}

# create the list of commits
#I'm explicitly filtering out some files that have irritating characters
#TODO: make this robust to irritating characters in file names (e.g. spaces)
echo "listing commit files on $DEFAULT_BRANCH to ${FILE_COMMITS}"
pv ${FILE_FILESTATUS} | ag -v 'actionpack/test/fixtures/public/foo' |\
    gawk -F\\t 'BEGIN {OFS="\t"} FNR==NR {allow[$1]=1} FNR != NR {if($3 ~ /R[0-9][0-9][0-9]/) { if(allow[$4]) {print $1, $2, $3, $4;} if(allow[$5]) {print $1, $2, $3, $5;} } else if(allow[$4]) {print $0} }'\
        ${FILE_FILELIST} - |\
     tac | LC_ALL=C sort -k4 -s | uniq > ${FILE_COMMITS}

if [ ! -s ${FILE_COMMITS} ]; then
    echo "no commits found for files, nothing to analyze"
    unique_files=$(cat ${FILE_FILELIST} | grep -v '^$'  | wc -l)
    echo "${unique_files} files passed filtering for history"
    exit 1
fi

#TODO: sampling commits goes here (sample files and then get all related commits?)

#TODO: use git show batch interface. we could pass multiple shas into git show for the same file (although there's a limit to how big the command line can be, so batches of 10 are probably ok, but batches of 100 are probably not
# pull out diffs (git show)
#create diffs file
#gawk -F\\t '{printf("echo \"merging %s %s %s\"\n", $1, $2, $4);printf("git show -m --first-parent -U0 --oneline %s -- '"'"'%s'"'"'\n", $2, $4)}' |\
echo "get diffs from those commits (this might take a while) to ${FILE_LINES}"
cat ${FILE_COMMITS} |\
    gawk -F\\t 'function printgitshow(ncommits, commits, filename) {if(ncommits <= 0) { return; } quoted_filename=filename; if(quoted_filename !~ /^".*"$/) { quoted_filename=sprintf("\"%s\"", quoted_filename);} escaped_filename=filename; gsub(/[\\]/, "\\\\", escaped_filename); gsub(/"/, "\\\"", escaped_filename); printf("git show --no-renames -m --first-parent -U0 --format=\"merging %%H %%H %s%%x0A%%h %%s\" %s -- %s\n", escaped_filename, commits, quoted_filename);} BEGIN {commits="";ncommits=0} ncommits>=100 || $4 != lastf {printgitshow(ncommits, commits, lastf);ncommits=0; commits=""} {ncommits+=1; commits = commits " " $2; lastf=$4} END {printgitshow(ncommits, commits, lastf) }' |\
    bash | pv -Nbytes -c | tee >(gzip -c > ${FILE_LINES}) |\
    ag '^merging [a-f0-9]{40}' | pv -c -Ncommits -l -s$(cat ${FILE_COMMITS} | wc -l) > /dev/null

# follow line changes through from birth to death (command using process_diffs.awk, this outputs a log of birth/death events for lines, but also dumps the lines of code and new/old diff hunks for all commits)
#process diffs file (creates linelog with birth/death events,
#but also codefile, addfile, remfile which has code and new/old diff hunks
echo "follow line lifetime (like git blame. this might take a while) to ${FILE_LINELOG}"
echo "note, you might see a warning about invalid multibyte data, you can safely ignore that."
pv ${FILE_LINES} | zcat | gawk -v binariesfile=${FILE_BINARIESFILE} -v codefile=${FILE_CODEFILE} -v addfile=${FILE_ADDFILE} -v remfile=${FILE_REMFILE} -f ${DIR}/process_diffs.awk | gzip -c > ${FILE_LINELOG}
#binaries file can't be empty
echo "" >> ${FILE_BINARIESFILE}

#create some relevant metadata
#adding dates
echo "creating metadata about line lifetime to ${FILE_METADATA}"
pv ${FILE_LINELOG} | zcat |\
    gawk -F\\t 'BEGIN{OFS="\t"} FNR == 1 { fileindex+=1 } fileindex == 1 { commits[$1] = $2 } fileindex == 2 { binaries[$1] = 1 } fileindex==3 && commits[$3] == "" { print "birth commit not found on line", FNR > "/dev/stderr"; exit 1 } fileindex == 3 && commits[$6] == "" { print "latest commit not found on line", FNR > "/dev/stderr"; exit 1} fileindex == 3 && !binaries[$2] {print commits[$3], commits[$6], $0}' ${FILE_COMMIT_DATES} ${FILE_BINARIESFILE} - |\
    gawk -F\\t 'BEGIN {OFS="\t"} ($3 == "live" || $3 == "died") {print sprintf("%s\t%s\t%s", $4, $8, $9), $3, $1-$2, $1, $2, $5, $8}' |\
    LC_ALL=C sort -u -S500M |\
    gzip -c > ${FILE_METADATA}

# parse the code (command using parse_line.rb)
# create embedding model (command using embed_doc2vec.py via convoluted set of steps to merge metadata and code, shuffle and split data)
# embed code using that model (command using embed_doc2vec.py)
# parse new/old diffs (command using parse_line.rb)
# embed parsed new/old diffs (command using embed_doc2vec.py)
# join into single training file (command)


