#!/bin/bash

HOST=127.0.0.1
PORT=8888
METHOD=sc_getwork
AUTH=user:pass

curl -v http://$AUTH@$HOST:$PORT -X POST -d "{\"method\":\"$METHOD\",\"id\":1}" -H 'Content-Type: application/json'

echo ""

