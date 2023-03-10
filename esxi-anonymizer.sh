#
# ESXi VM Report Anonymizer
#
# use it only on ESXi hosts
# works with standard VMware binaries
#
# https://github.com/nevrax/vmware-esxi-tools
#

debug_param=${4:-debug}

fancymsg() {
       test $debug_param == "debug" && echo "$*"
}

errmsg() {
	fancymsg "error: $*"
	exit 1
}

# works on ESXi 7.x
# not working properly on Liunx since find command has many implementations
# not working properly on MacOS since sed command has a non-gnu implementation
# not tested on Windows WSL/2
test "$(uname)" != "VMkernel" && errmsg please use this script only on ESXi hosts

# give me something to work with
test $# -lt 2 && errmsg need proper parameters. usage: ./$(basename $0) datastoreFullPath reportFullPath [filter] [nodebug]

# your working directory for storing input and output files
base_dir=${2:-/tmp}
# remove slash sign at the end of the report path 
base_dir=$(echo $base_dir | sed 's/\/\+$//g')
fancymsg baseWorkingDirectory: $base_dir

# your vmware datastore path to search for files
ds_path=${1:-/tmp}
# only one slash sign allowed at the end
ds_path="$(echo $ds_path | sed 's/\/\+$//g')/"
fancymsg datastrorePath: $ds_path

# session name
session_name=$(date +"%Y%m%d_%H%M%S")
fancymsg sessionName: $session_name

session_dir="${base_dir}/${session_name}"
mkdir -p "${session_dir}" 2>/dev/null
if [ -d "${session_dir}" ]; then
	fancymsg sessionWrkDir: $session_dir created successfully
else
	errmsg cannot create $session_dir
fi

session_orig_wf="${session_dir}/orig-words.txt"
session_anon_wf="${session_dir}/anon-words.txt"
session_enc_sedf="${session_dir}/session-encrypt.sed"
session_dec_sedf="${session_dir}/session-decrypt.sed"
session_anon_out="${session_dir}/anonymous-output.txt"
session_anon_rev="${session_dir}/anonymous-revert.txt"

# contains a list files to be anonimized
# generated by find command
original_input_file="${session_dir}/original-input.txt"

# contains all words found in file names from your original input
# excludes typical vmware words found in file name
# excludes all words found in file extension
# generated by filtering original input
orig_words_dict_file="${session_dir}/orig-words.dictionary.txt"

# anonymous base dictinoary
anon_base_dict_file="$(dirname "$0")/bip39-english.dictionary.txt"
if [ -f "${anon_base_dict_file}" ]; then
	fancymsg baseDictAnonFile: $anon_base_dict_file
else
	fancymsg tryThis: wget --no-check-certificate https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt -O $anon_base_dict_file
	errmsg base anonymous dictionary file $anon_base_dict_file not found!
fi

# contains words used to anonymize original input words
# use a bip39 dictionary if less than 2048 original words
# not generated, needs to be provided
anon_words_dict_file="${session_dir}/anon-words.dictionary.txt"

# download step not required
# use this if you don't want to build a custom dictionary
# temporary permit http trafic on esxi
## esxcli network firewall ruleset set --ruleset-id=httpClient --enabled=true
# download a standard bip39 english words files, skip ssl check for expired or self signed certificates
## wget --no-check-certificate https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt -O $anon_base_dict_file
# disabled http trafic on esxi, default setting
## esxcli network firewall ruleset set --ruleset-id=httpClient --enabled=false
# randomize bip39 dictionary
#
fancymsg baseDictAnonRndm: radomize anonymous base dictionary
cat $anon_base_dict_file | awk 'BEGIN{srand()}{printf "%06d %s\n", rand()*1000000, $0;}' | sort -n | cut -d" " -f2 > $anon_words_dict_file

# just a quick check
find "$ds_path" -type f > /dev/null && fancymsg "findCmdCheck: got recursive access on $ds_path"

# hide some files before even starting
start_filter=${3:-just-a-simple-fil3r}
fancymsg startFilter: $start_filter

# make a list of files you want to anonymize
find "$ds_path" -type f | grep -v -i -E "$start_filter" | sort > $original_input_file

# get a list of extensions for all files on your vmware datastore
extensions=$(cat $original_input_file | grep -o -E '\w+$' | sort -u)

# create a grep filter with all file exensions found
extensions_filter=$(echo $extensions | sed 's/ /|/g')

# quick check for extensions found
fancymsg extensionsFiter: $extensions_filter

# some words found in tipical vmware file names or extensions
# you want to keep these words, not to anonimize their names
vmware_filter="vmware|aux|flat|quiesce|manifest|sesparse|snapshot|delta|rdmp|rdm|iscsi"
fancymsg vmwareFiler: $vmware_filter

# compute a list of words to be anonymized
# sed 's/_/ /g' aka names with _ (underscore) to be split into separate words
# grep -o -E '\w+ aka words (including numbers) found in file names
# sort -u aka sort the results, removing duplicates, case sensitive
# grep -v -i -w -E aka inverted filter (v), case insensitive (i), use regexp (E), match word (w)
# ^[0-9]{1,}$ aka keep words with numbers only, at least one decimal
# $extensions_filter aka do not anonymize file extensions
# $vmware_filter aka do not anonymize vmware keywords used in file names
orig_words=$(cat $original_input_file | sed 's/_/ /g' | grep -o -E '\w+' | sort -u | grep -v -i -w -E "$extensions_filter" | grep -v -i -E '^[0-9]{1,}$' | grep -v -i -E "$vmware_filter")
orig_words_filter=$(echo ${orig_words} | sort -u | sed 's/ /|/g')

# quick test for original worlds to be anonymized
fancymsg origWordsFilter: $orig_words_filter

# create a dictionary files with filtered words found in file names
echo "$orig_words" > $orig_words_dict_file

# how many words you've got in original dictionary
orig_wcount=$(wc -l $orig_words_dict_file | awk '{print $1}')
fancymsg origWordsCount: $orig_wcount

# how many words you've got in anonymous dictionary
anon_wcount=$(wc -l $anon_words_dict_file | awk '{print $1}')
fancymsg anonWordsCount: $anon_wcount

# in case of large reports you might run out of words to encode
test $anon_wcount -lt $orig_wcount && errmsg too many more words to encode, more than available anonymous words

# original dictionary used on this session
head -n $orig_wcount $orig_words_dict_file > $session_orig_wf
fancymsg origTmpDict: $session_orig_wf

# anon dictionary used on this session
# exclude orig words and vmware words to simplify mappings
# limit anon dictionary to the same number of orig words
cat $anon_words_dict_file | grep -v -i -E "$orig_words_filter" | grep -v -i -E "$vmware_filter" | head -n $orig_wcount $anon_words_dict_file > $session_anon_wf
fancymsg anonTmpDict: $session_anon_wf

# generate encoding mappings for sed command
while read -r -u 3 orig && read -r -u 4 anon; do echo "s/\b${orig}\b/${anon}/g"; done 3<"${session_orig_wf}" 4<"${session_anon_wf}" > $session_enc_sedf
fancymsg sedCmdEncWords: $session_enc_sedf

# generate deconding mappings for sed commad
while read -r -u 3 orig && read -r -u 4 anon; do echo "s/\b${anon}\b/${orig}/g"; done 3<"${session_orig_wf}" 4<"${session_anon_wf}" > $session_dec_sedf
fancymsg sedCmdDecWords: $session_dec_sedf

# THIS IS WHERE THE MAGIC HAPPENS
sed -f $session_enc_sedf $original_input_file > $session_anon_out
# END OF MAGIC STUFF
fancymsg origInFile: $original_input_file
fancymsg anonOutFile: $session_anon_out

# decode the encoding for comparison
sed -f $session_dec_sedf $session_anon_out > $session_anon_rev
fancymsg revertedFile: $session_anon_rev

# better safe than sorry
fancymsg reportNote: please check if your data output is anonymized before sending it out             
fancymsg reportNote: VMware might change grep, sed, find, awki, echo, diff implementation             

# sha256 check
sha256_orig=$(sha256sum $original_input_file | cut -d" " -f1)
sha256_rvrt=$(sha256sum $session_anon_rev | cut -d" " -f1)
fancymsg origInSha256Check: $sha256_orig
fancymsg encDecSha256Check: $sha256_rvrt

if [ "${sha256_orig}" == "${sha256_rvrt}" ]; then
	fancymsg sessionResult: SUCCESS! decoded anonymized report is identical to original report
else
	errmsg some new words aka new files messed up the encoding. try again or try a path with fewer files!
fi

# diff check
fancymsg diffCheck: $original_input_file vs $session_anon_rev
diff -s $original_input_file $session_anon_rev
