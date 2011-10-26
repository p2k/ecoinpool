#!/bin/bash

PORT=8332
#PORT=8555
METHOD=sc_getwork
AUTH=user:pass

curl -v http://$AUTH@127.0.0.1:$PORT -X POST -d "{\"method\":\"$METHOD\",\"id\":1}" -H 'Content-Type: application/json'

echo ""

