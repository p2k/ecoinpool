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

SERVER_URL = "http://ecoinpool.p2k-network.org:5984/"
SHARES_DB = "sc-livetest2"
CONFIG_DB = "ecoinpool"

# ---------------------

from couchdb.client import Server

class ShareMonitor(object):
    def __init__(self, server_url, shares_db, config_db):
        self.server = Server(server_url)
        self.shares_db = self.server[shares_db]
        self.config_db = self.server[config_db]
        
        self.worker_dict = {}
    
    def getWorker(self, worker_id):
        worker = self.worker_dict.get(worker_id)
        if worker is None:
            worker = self.config_db.get(worker_id)
            self.worker_dict[worker_id] = worker
        return worker
    
    def run(self):
        update_seq = self.shares_db.info()["update_seq"]
        current_block = None
        print "* Share Monitor activated *"
        
        for row in self.shares_db.changes(feed="continuous", since=update_seq):
            if not row.has_key("id"):
                print "?", row
                continue
            
            doc_id = row["id"]
            doc = self.shares_db.get(doc_id)
            if not doc.has_key("state"):
                continue
            
            if doc.has_key("block_num") and current_block != doc["block_num"]:
                print "Current block: %d" % doc["block_num"]
                current_block = doc["block_num"]
            
            worker = self.getWorker(doc["worker_id"])
            
            text = None
            if doc["state"] == "valid":
                text = "+ Valid share from %s/%s."
            elif doc["state"] == "candidate":
                text = "+++ Candidate share from %s/%s! +++"
            elif doc["state"] == "invalid":
                if doc["reject_reason"] == "stale":
                    text = "- Stale share from %s/%s!"
                elif doc["reject_reason"] == "duplicate":
                    text = "- Duplicate work from %s/%s!"
                elif doc["reject_reason"] == "target":
                    text = "- Invalid hash from %s/%s!"
                elif doc["reject_reason"] == "data":
                    text = "- Wrong data from %s/%s!"
            
            if text is not None:
                timestamp = "%d-%02d-%02d %02d:%02d:%02d" % tuple(doc["timestamp"])
                print ("[%s] " + text) % (timestamp, worker["name"], doc["ip"])

if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    ShareMonitor(SERVER_URL, SHARES_DB, CONFIG_DB).run()
