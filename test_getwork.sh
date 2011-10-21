#!/bin/bash

curl -v http://user:pass@127.0.0.1:8332 -X POST -d '{"method":"getwork","id":1}' -H 'Content-Type: application/json'

echo ""

