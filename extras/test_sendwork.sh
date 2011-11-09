#!/bin/bash

HOST=127.0.0.1
PORT=8888
AUTH=user:pass

curl -v http://$AUTH@$HOST:$PORT -X POST -d @work.txt -H 'Content-Type: application/json'

echo ""

