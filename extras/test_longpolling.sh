#!/bin/bash

#HOST=ecoinpool.p2k-network.org
#PORT=8888
HOST=localhost
PORT=8332
METHOD=sc_getwork
AUTH=p2k:pass

curl -v http://$AUTH@$HOST:$PORT/LP -X GET

echo ""

