#!/bin/bash
# drop - push the encrypted newest bundle to the PRIVATE repo 0x2e8b/diag-drop via GitHub device login, then log out
#   bash drop.sh <password>      login: open https://github.com/login/device on YOUR laptop and type the code shown here
set -u
PW=${1:?password}; F=$(ls -t /root/diag/bundle-*.tgz 2>/dev/null | head -1); [ -r "$F" ] || { echo "run bash bundle.sh first"; exit 1; }
command -v gh >/dev/null || { echo "installing gh ..."; apt-get install -y gh >/dev/null 2>&1 || { echo "apt install gh failed"; exit 1; }; }
gh auth status >/dev/null 2>&1 || gh auth login -h github.com -p https -w -s repo || exit 1
gh auth setup-git
D=$(mktemp -d); trap 'rm -rf $D; gh auth logout -h github.com 2>/dev/null; echo "gh logged out"' EXIT
git clone -q https://github.com/0x2e8b/diag-drop $D/r || exit 1
openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:"$PW" -in "$F" -out $D/r/$(basename $F).enc || exit 1
cd $D/r && git add -A && git -c user.name=diag -c user.email=diag@localhost commit -qm "$(basename $F)" && git push -q && echo "pushed $(basename $F).enc"
