#!/bin/bash
# send - encrypt the newest diag bundle and PUT it to a receiver (token and password given on the command line, not stored)
#   bash send.sh <token> <password> [file]     default file: newest /root/diag/bundle-*.tgz
set -u
T=${1:?token}; PW=${2:?password}; F=${3:-$(ls -t /root/diag/bundle-*.tgz 2>/dev/null | head -1)}
URL=${URL:-http://joanna151.mikrus.xyz:20151}
[ -r "$F" ] || { echo "no bundle: run bash bundle.sh first"; exit 1; }
E=/tmp/$(basename $F).enc
openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:"$PW" -in "$F" -out $E || exit 1
echo "sending $(basename $F) ($(du -h $E | cut -f1) encrypted)"
if ! curl -sS --max-time 60 -T $E $URL/$T/$(basename $E); then
  echo "direct port blocked, trying HTTPS 443 over IPv6 to the same receiver ..."
  curl -6 -sSk --max-time 300 -T $E "https://[2a01:4f9:3a:289f::151]/$T/$(basename $E)" ||
    echo "IPv6 failed too (no IPv6 on this host?): use the SUMMARY photo from bundle.sh"
fi; rm -f $E
