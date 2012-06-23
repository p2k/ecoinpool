#!/bin/bash

if [ "$1" == "" ];then
  echo "Usage: `basename $0` <method> [param]"
  exit 1
fi

HOST=127.0.0.1
PORT=8887 #8332
METHOD=$1
AUTH=user:pass

if [ "$2" == "" ];then
  curl http://$AUTH@$HOST:$PORT -X POST -d "{\"method\":\"$1\",\"id\":1}" -H 'Content-Type: application/json'
elif [ "$3" == "" ];then
  curl http://$AUTH@$HOST:$PORT -X POST -d "{\"method\":\"$1\",\"params\":[\"$2\"],\"id\":1}" -H 'Content-Type: application/json'
else
  curl http://$AUTH@$HOST:$PORT -X POST -d "{\"method\":\"$1\",\"params\":[\"$2\",\"$3\"],\"id\":1}" -H 'Content-Type: application/json'
fi

echo ""

