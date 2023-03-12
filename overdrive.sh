#!/usr/bin/env bash

set -e # exit immediately on first error
set -o pipefail # propagate intermediate pipeline errors

# should match `git describe --tags` with clean working tree
VERSION=2.3.2

OMC=1.2.0
OS=10.11.6
# use same user agent as mobile app
UserAgent='OverDrive Media Console'
UserAgentLong='OverDrive Media Console/3.7.0.28 iOS/10.3.3'

RESET() {
	>&2 tput sgr0
}

DEBUG() {
	return 0;
    >&2 echo -ne "\033[2;32m"
    >&2 echo "$@"
	RESET
}

INFO() {
    >&2 echo -ne "\033[36m"
    >&2 echo "$@"
	RESET
}

WARN() {
    >&2 echo -ne "\033[1;33m"
    >&2 echo "$@"
	RESET
}

ERROR() {
    >&2 echo -e "\033[1;31m"
    >&2 echo "$@"
	RESET
}

usage() {
  local CMD=($basename "$0")
  INFO "
Usage: $(basename "$0") command 
	[command2 ...] book.odm [book2.odm ...]
	[-h|--help]
	[-v|--verbose]

Commands:
  download   Download the mp3s for an OverDrive book loan.
  return     Process an early return for an OverDrive book loan.
  info       Print the author, title, and total duration (in seconds) for each OverDrive loan file.
  metadata   Print all metadata from each OverDrive loan file.
"
}

MEDIA=()
COMMANDS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--verbose)
      set -x
      WARN 'Entering debug (verbose) mode\n'
      ;;
    *.odm)
      MEDIA+=("$1")
      ;;
    download|return|info|metadata)
      COMMANDS+=("$1")
      ;;
    *)
      ERROR "Unrecognized argument: $1"
      exit 1
      ;;
  esac
  shift
done

if [[ ${#MEDIA[@]} -eq 0 || ${#COMMANDS[@]} -eq 0 ]]; then
  usage
  [[ ${#COMMANDS[@]} -eq 0 ]] && ERROR 'You must supply at least one command'
  [[ ${#MEDIA[@]} -eq 0 ]] && ERROR 'You must supply at least one media file (the .odm extension is required)'
  exit 1
fi


_download(){
	local URL=$1
	local OUTPUT=$2

    curl --retry 5 -L --silent --show-error --user-agent "$UserAgent" --output "$OUTPUT" "$URL" 
	return $?
}

_xmllint_iter_xpath() {
  # Usage: _xmllint_iter_xpath /xpath/to/list file.xml [/path/to/value]
  #
  # Iterate over each XPath match, separated by newlines.
  count=$(xmllint --xpath "count($1)" "$2")
  for i in $(seq 1 "$count"); do
    if [[ $i != 1 ]]; then
      printf '\n'
    fi
    xmllint --xpath "string($1[position()=$i]$3)" "$2"
  done
}

_get_clientid() {
	ConfigDir=~/".config/overdrive.sh"

	if [ ! -d "$ConfigDir" ]; then
		WARN "Creating directory $ConfigDir"
		mkdir -p "$ConfigDir"
	fi

	ConfigFile="$ConfigDir"/ClientID

	if [ -e "$ConfigFile" ]; then
		cat "$ConfigFile"
	else
		DEBUG 'Generating random ClientID'
		ClientID=$(uuidgen | tr '[:lower:]' '[:upper:]')
		INFO "ClientID=$ClientID"
		echo -n "$ClientID" > $ConfigFile
		echo -n "$ClientID"
	fi
}

acquire_license() {
  # Usage: acquire_license book.odm book.license
  #
  # Read the license signature from book.license if it exists; if it doesn't,
  # acquire a license from the OverDrive server and write it to book.license.
  if [[ -e $2 ]]; then
    INFO "License already acquired: $2"
  else
    # generate random Client ID
	ClientID=$(_get_clientid)

    # first extract the "AcquisitionUrl"
    AcquisitionUrl=$(xmllint --xpath '/OverDriveMedia/License/AcquisitionUrl/text()' "$1")
    INFO "Using AcquisitionUrl=$AcquisitionUrl"

    MediaID=$(xmllint --xpath 'string(/OverDriveMedia/@id)' "$1")
    INFO "Using MediaID=$MediaID"

    # Compute the Hash value; thanks to https://github.com/jvolkening/gloc/blob/v0.601/gloc#L1523-L1531
    RawHash="$ClientID|$OMC|$OS|ELOSNOC*AIDEM*EVIRDREVO"
    DEBUG "Using RawHash=$RawHash"
    Hash=$(echo -n "$RawHash" | iconv -f ASCII -t UTF-16LE | openssl dgst -binary -sha1 | base64)
    DEBUG "Using Hash=$Hash"

    _download "$AcquisitionUrl?MediaID=$MediaID&ClientID=$ClientID&OMC=$OMC&OS=$OS&Hash=$Hash" "$2"
  fi
}

extract_metadata() {
  # Usage: extract_metadata book.odm book.metadata
  #
  # The Metadata XML is nested as CDATA inside the the root OverDriveMedia element;
  # luckily, it's the only text content at that level
  # sed: delete CDATA prefix from beginning of first line, and suffix from end of last line
  # N.b.: tidy will still write errors & warnings to /dev/stderr, despite the -quiet
  if [[ -e $2 ]]; then
    DEBUG "Metadata already extracted: $2"
  else
    xmllint --noblanks --xpath '/OverDriveMedia/text()' "$1" \
    | sed -e '1s/^<!\[CDATA\[//' -e '$s/]]>$//' \
    | tidy -xml -wrap 0 -quiet > "$metadata_path"
  fi
}

extract_author() {
  # Usage: extract_author book.odm.metadata
  # Most Creator/@role values for authors are simply "Author" but some are "Author and narrator"
  _xmllint_iter_xpath "//Creator[starts-with(@role, 'Author')][position()<=3]" "$1" \
  | awk 'NF' | sed ':a; N; $!ba; s/\n/, /g'
}

extract_title() {
  # Usage: extract_title book.odm.metadata
  xmllint --xpath '//Title/text()' "$1"
}

extract_subtitle() {
  # Usage: extract_title book.odm.metadata
  xmllint --xpath 'concat(//SubTitle/text(), "")' "$1"
}

extract_duration() {
  # Usage: extract_duration book.odm
  #
  # awk: `-F :` split on colons; for MM:SS, MM=>$1, SS=>$2
  #      `$1*60 + $2` converts MM:SS into seconds
  #      `{sum += ...} END {print sum}` output total sum (seconds)
  _xmllint_iter_xpath '//Part' "$1" '/@duration' \
  | awk -F : '{sum += $1*60 + $2} END {print sum}'
}

extract_filenames() {
  # Usage: extract_filenames book.odm
  _xmllint_iter_xpath '//Part' "$1" '/@filename' \
  | sed -e "s/{/%7B/" -e "s/}/%7D/"
}

extract_coverUrl() {
  # Usage: extract_coverUrl book.odm.metadata
  xmllint --xpath '//CoverUrl/text()' "$1" \
  | sed -e "s/{/%7B/" -e "s/}/%7D/"
}

extract_thumbnailUrl() {
  # Usage: extract_thumbnailUrl book.odm.metadata
  xmllint --xpath '//ThumbnailUrl/text()' "$1" \
  | sed -e "s/{/%7B/" -e "s/}/%7D/"
}

download() {
  # Usage: download book.odm
  #
  license_path=$1.license
  acquire_license "$1" "$license_path"
  DEBUG "Using License="$(cat "$license_path")

  # the license XML specifies a default namespace, so the XPath is a bit awkward
  ClientID=$(xmllint --xpath '//*[local-name()="ClientID"]/text()' "$license_path")
  INFO "Using ClientID=$ClientID from License"

  # extract metadata
  metadata_path=$1.metadata
  extract_metadata "$1" "$metadata_path"

  # extract the author and title
  Author=$(extract_author "$metadata_path")
  DEBUG "Using Author=$Author"
  Title=$(extract_title "$metadata_path")
  
  SubTitle=$(extract_subtitle "$metadata_path")
  DEBUG "Using SubTitle=$SubTitle"

  # prepare to download the parts
  baseurl=$(xmllint --xpath 'string(//Protocol[@method="download"]/@baseurl)' "$1")

  dir="$Title"

  if [[ ! -z $SubTitle ]]; then
	dir="$dir - $SubTitle"
  fi
  dir="$dir [$Author]"
  dir=`echo -n "$dir" | tr '/' '|' | tr "\n" ' '`
  mkdir -vp "$dir"

  while read -r path; do
    # delete from path up until the last hyphen to the get Part0N.mp3 suffix
	if [ -z "$path" ]; then
        DEBUG "Skipping empty path"
	else
    suffix=${path##*-}
    output="$dir/$Title-$suffix"
      DEBUG "Downloading $path -> $output"
      if curl -L \
		  --retry 5\
		  --retry-max-time 0 \
		  --retry-all-errors \
		  --progress-bar \
		  -C - \
          -A "$UserAgent" \
          -H "License: $(cat "$license_path")" \
          -H "ClientID: $ClientID" \
          --compressed -o "$output" \
          "$baseurl/$path"; then
        INFO "Downloaded $output successfully"
      else
        STATUS=$?
        WARN "Failed trying to download $output"
        rm -f "$output"
        return $STATUS
      fi
	fi
  done < <(extract_filenames "$1")

  CoverUrl=$(extract_coverUrl "$metadata_path")
  DEBUG "Using CoverUrl=$CoverUrl"
  if [[ -n "$CoverUrl" ]]; then
      cover_output=$dir/folder.jpg
      DEBUG "Downloading $cover_output"
      if _download "$CoverUrl" "$cover_output";
	  then
        INFO "Downloaded cover image successfully"
      else
        STATUS=$?
        WARN 'Failed trying to download cover image'
        rm -f "$cover_output"
        return $STATUS
      fi
  else
    WARN 'Cover image not available'
  fi

  ThumbnailUrl=$(extract_thumbnailUrl "$metadata_path")
  DEBUG "Using ThumbnailUrl=$CoverUrl"
  if [[ -n "$ThumbnailUrl=" ]]; then
      thumbnail_output=$dir/folder_thumb.jpg
      DEBUG "Downloading $thumbnail_output"
      if _download "$ThumbnailUrl" "$thumbnail_output";
	  then
        INFO "Downloaded thumbnail image successfully"
      else
        STATUS=$?
        WARN 'Failed trying to download thumbnail image'
        rm -f "$thumbnail_output"
        return $STATUS
      fi
  else
    WARN 'Thumbnail image not available'
  fi
}

early_return() {
  # Usage: early_return book.odm
  #
  # return is a bash keyword, so we can't use that as the name of the function :(

  # Read the EarlyReturnURL tag from the input odm file
  EarlyReturnURL=$(xmllint --xpath '/OverDriveMedia/EarlyReturnURL/text()' "$1")
  INFO "Using EarlyReturnURL=$EarlyReturnURL"

  _download "$EarlyReturnURL" /dev/null
  # that response doesn't have a newline, so one more superfluous log to clean up:
  INFO 'Finished returning book'
}

info() {
  # Usage: info book.odm
  metadata_path=$1.metadata
  extract_metadata "$1" "$metadata_path"
  printf 'Author:\t%s\nTitle:\t%s\nSubtitle:\t%s\nDuration:\t%d seconds\n' "$(extract_author "$metadata_path")" "$(extract_title "$metadata_path")" "$(extract_subtitle "$metadata_path")" "$(extract_duration "$1")"
}

metadata() {
  # Usage: metadata book.odm
  metadata_path=$1.metadata
  extract_metadata "$1" "$metadata_path"
  xmllint --format "$metadata_path" | sed 1d
}

# now actually loop over the media files and commands
for ODM in "${MEDIA[@]}"; do
  INFO "processing file $ODM"
  for COMMAND in "${COMMANDS[@]}"; do
    case $COMMAND in
      download)
        download "$ODM"
        ;;
      return)
        early_return "$ODM"
        ;;
      info)
        info "$ODM"
        ;;
      metadata)
        metadata "$ODM"
        ;;
      *)
        ERROR "Unrecognized command: $COMMAND"
        exit 1
        ;;
    esac
  done
done
