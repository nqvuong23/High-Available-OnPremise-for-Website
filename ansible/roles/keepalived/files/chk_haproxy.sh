#!/bin/bash
# a live process that stopped answering is still a failure
curl -sf -m 1 -o /dev/null http://127.0.0.1/haproxy-alive
