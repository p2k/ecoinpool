#!/usr/bin/env python2

#
# Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
#
# This file is part of ecoinpool.
#
# ecoinpool is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# ecoinpool is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
#

# -- Configure here: --

POOL_HOST = "ecoinpool.p2k-network.org:8888"
POOL_USER = "" # <-- Please set the username here
POOL_PASS = "pass"

SC_HOST = "localhost:8555"
SC_USER = "user"
SC_PASS = "pass"
SC_MINER = 4 # The miner to restart; this starts with 0 (= Solo), 4 is usually "Other"

# ---------------------

import httplib, time, os, sys

def make_basic_auth(user, pwd):
    return "Basic " + ("%s:%s" % (user, pwd)).encode("base64").strip()

def make_connection(host):
    spl = host.split(":")
    if len(spl) == 1:
        return httplib.HTTPConnection(host, 80, timeout=3600)
    else:
        return httplib.HTTPConnection(spl[0], int(spl[1]), timeout=3600)

def post_request(host, user, pwd, method, params=[]):
    conn = host if isinstance(host, httplib.HTTPConnection) else make_connection(host)
    headers = {"Authorization": make_basic_auth(user, pwd), "Content-Type": "application/json"}
    data = '{"method":"%s","params":%s,"id":1}' % (method, repr(params).replace("'", '"').replace("True", "true").replace("False", "false"))
    conn.request("POST", "/", data, headers)
    return conn

def get_request(host, user, pwd, path):
    conn = host if isinstance(host, httplib.HTTPConnection) else make_connection(host)
    headers = {"Authorization": make_basic_auth(user, pwd)}
    conn.request("GET", path, headers=headers)
    return conn

def wait_for_lp():
    c = get_request(POOL_HOST, POOL_USER, POOL_PASS, "/LP")
    if len(c.getresponse().read()) > 0:
        timeout = True
    else:
        timeout = False
    c.close()
    return timeout

def exit():
    if not hasattr(os, "uname"):
        raw_input("\n-- Press enter to exit --\n")
    sys.exit(1)

def main():
    # Checking local btc
    try:
        c = post_request(SC_HOST, SC_USER, SC_PASS, "getinfo")
    except:
        print "Error: Could not connect to the local SC client."
        exit()
    
    if not '"error":null' in c.getresponse().read():
        print "Local SC returned errors."
        c.close()
        exit()
    
    print "+ ecoinpool LP ready +"
    
    while True:
        if wait_for_lp():
            sys.stdout.write(".")
            sys.stdout.flush()
            c = post_request(c, SC_USER, SC_PASS, "sc_setmining", [SC_MINER, False])
            c.getresponse().read()
            time.sleep(0.25)
            c = post_request(c, SC_USER, SC_PASS, "sc_setmining", [SC_MINER, True])
            c.getresponse().read()
        else:
            sys.stdout.write(",")
            sys.stdout.flush()

if __name__ == "__main__":
    if len(POOL_USER) == 0:
        print "Please open this script in a text editor and set a username!"
        exit()
    
    import signal
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    main()
