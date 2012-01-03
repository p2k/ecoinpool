
ecoinpool
=========

A pool mining software written in Erlang for cryptographic currencies.

Beta Release
------------

This is the first release of ecoinpool and denotes the beta phase of the project.
A quite large piece of work has been done to get this from zero to a full-fledged
coin pool software, yet not everything is 100% solid and waterproof and some
features are missing in this version. Nevertheless, everything you need to get
started and give it a try is there.

ecoinpool supports Bitcoin, Bitcoin+Namecoin (merged), Litecoin, Fairbrix
and Solidcoin.

Contact
-------

ecoinpool is written and maintained by Patrick "p2k" Schneider.

* Jabber/XMPP: p2k@jabber.p2k-network.org
* IRC: #ecoinpool on Freenode - my nick is `mega_p2k` there
* [Message via GitHub](https://github.com/inbox/new/p2k)

Installing
----------

Follow this guide to install your instance of ecoinpool. The software has been
tested on Linux and MacOS X but should also work on Windows. If you really want
to use this on Windows, the console instructions might be a bit different; you
are on your own there.

### Dependencies ###

ecoinpool only has a few dependencies you have to install yourself. The required
Erlang applications are downloaded and compiled later with the help of
[rebar](https://github.com/basho/rebar), the build-tool of my choice, which
comes bundled with ecoinpool.

For the following software, you have to consult your operating system's package
manager or get a binary release or compile from source.

* [GIT](http://git-scm.com/download) - not only to download this project, but
  also for getting the Erlang dependencies
* [Erlang/OTP](http://www.erlang.org/download.html) - **at least R14B is required**;
  ecoinpool also works on the newly released R15B
* [CouchDB](http://couchdb.apache.org/downloads.html) - **minimum is 1.1.1**;
  tests on newer releases like 1.2.0 and 1.3.0 (latest from the GIT repository)
  have been successful too
* C compiler - preferably GCC; required to build external modules for the hash
  algorithms and for some speedup

### Bootstrapping ###

First time installation instructions:

1. Get ecoinpool's source code by cloning the GIT repository into a folder of
   your choice.
2. Open a console, cd into the source folder and run `./rebar get-deps` - this
   will take care of all the Erlang dependencies required by ecoinpool. They
   will be installed into the "deps" folder which will be created if it doesn't
   exist.
3. Run `./rebar compile` - this will compile all dependencies and the main
   applications.
4. Find and open CouchDB's local config file, usually at /etc/couchdb/local.ini.
5. Within the `[httpd]` section, add a line `bind_address = 0.0.0.0` in order to
   allow access from the internet (required if you want to expose the built-in
   web frontend to your users). Also make sure port 5984 can be reached. If you
   installed CouchDB from source, you have to allow write access to that ini
   file from CouchDB's process.
5. Start CouchDB and browse to its local web frontend at
   `http://<your domain>:5984/_utils/`
6. On the lower right corner it'll say "Welcome to Admin Party!".
   Click "Fix this" and create an admin account for ecoinpool with a password of
   your choice. Note it down for later. Optionally create another admin account
   for yourself.

Configuring and Starting
------------------------

Before you can start ecoinpool, you have to configure the CouchDB connection. To
do that, open `test_launch.config` and follow the instructions. Ignore the
section about the MySQL Replicator for now (full documentation for that has not
been written yet).

In case you wonder where to configure the aspects of a pool server, this is done
completely throuch CouchDB and/or the web frontend of ecoinpool. We'll get to
this right now.

Start up ecoinpool with `./test_launch.sh` - if everything's alright you should
see a welcome banner. The software does not daemonize in this beta version. If
you want to be able to close your console and keep the server running, you might
want to try [GNU Screen](http://www.gnu.org/software/screen/) like this:
`screen -D -R -S ecoinpool_test ./test_launch.sh`

It might be worth knowing that you are on an Erlang console now. You can enter
some commands and evaluate expressions (not covered in this readme). All console
commands end with a period followed by a newline.

If you like to stop ecoinpool, you can quit via Ctrl+G and entering "q" at the
prompt. Alternatively you can hit Ctrl+C and enter "a" or simply kill the
process. There is no shutdown procedure required to be run, it's perfectly safe
to kill the process at any time. This is called "crash-only design". If you
still want to exit ecoinpool gracefully (which, as a little motivation, will
send "Server Terminating" as an error message to connected clients) enter `q().`
at the console.

After you started ecoinpool, head over to the main site at
`http://<your domain>:5984/ecoinpool/_design/site/_show/home`. It should say
"This server has been freshly installed and is not configured yet. Fix this.". In
case you're no longer logged in on CouchDB (ecoinpool uses CouchDB's user and
authentication system), do so by clicking "Login" on the lower right corner. The
"Fix this" link will only appear for an admin user. Click it now.

You will see the Subpool configuration page. It should be self-explanatory. You
can use "btc-pool" as a name and port 8888, if you don't know what to choose
there. If you want merged mining (only for BitCoin), choose the desired chain
from the list at "Aux Pool Chain" (currently only NameCoin) and enter e.g.
"nmc-pool" as Aux Pool Name.

For the CoinDaemon and AuxDaemon configuration, an ebitcoin client can be chosen.
See the section about "ebitcoin" below on how to set this up.

Hit "Save Configuration" above when you're finished. Finally click
"Activate Subpool" after the page reloaded and your pool is running.

Creating Accounts And Workers
-----------------------------

Accounts can be created by clicking "Signup" on the lower right corner (when not
logged in, of course). Regular users cannot change the pool configuration and
inactive Subpools are hidden too. This is enforced by CouchDB's authentication
mechanism.

After choosing a Subpool, the "My Workers" page will show up and new Workers can
be created by clicking "Add Worker" on the top left corner. A default worker
with the same name as the user is created the first time the button is clicked.
After that, more workers of the form `username_suffix` can be created. Passwords
are ignored in this beta version, any password will be accepted.

The "My Workers" page will also act as a live monitoring page, one of the most
exciting features of ecoinpool.

Updating
--------

The hot code reloading feature is not avaliable during this beta release. For
now, it is easier to just restart the server quickly. Just pull the latest
changes from the repository, kill the server and launch it again. All changed
modules will be recompiled automatically if you use the `test_launch.sh` script.

ebitcoin
--------

ecoinpool comes bundled with ebitcoin, a block monitor and mini block explorer
for bitcoin chains. ebitcoin is configured in the same way as ecoinpool, using
a built-in web frontend.

The main site for ebitcoin is at
`http://<your domain>:5984/ebitcoin/_design/site/_show/home`. You will also find
a link to ebitcoin within the sidebar of ecoinpool below "Other". If you visit
the site for the first time, it should say "This server has been freshly
installed and is not configured yet. Fix this.", just like for ecoinpool. Again,
you must be logged in to access the configuration.

After clicking the link, you will see the Client configuration page. Choose one
of the supported block chains, enter a name and optionally configure the host
and port of the daemon you want to connect to.

Hit "Save Configuration" when you're finished. Finally click "Activate Client"
after the page reloaded and ebitcoin will start synchronizing the block chain.
This will take some minutes depending on the chain size. You can follow the
process on the console or by looking at the logfiles.

To use a client with ecoinpool, open the Subpool via ecoinpool's web interface.
On the configuration tab you can select an ebitcoin client from within the
CoinDaemon and the AuxDaemon configuration panel. Only compatible clients will
be displayed.

Technical information: In the current implementation, ebitcoin will only store
block headers (for Namecoin, this includes the aux proof-of-work).

Compaction
----------

ebitcoin's block header databases and ecoinpool's share databases can become
quite large over time. To leverage the problem of running out of disk space,
CouchDB offers a compaction feature which can greatly reduce the needed disk
space per database. You can manually trigger the compaction through CouchDB's
web frontend by opening the database as admin, clicking "Compact & Cleanup..."
on the toolbar, choosing "Compact Database" and clicking "Run". You can watch
the compaction process on the status page (within the sidebar menu).

To trigger compaction via a cronjob during off-peak hours, you can use curl
like this:

    curl -H "Content-Type: application/json" -X POST http://<username>:<password>@localhost:5984/<database name>/_compact

Do this for each block chain or pool database. It is also recommended to run a
compaction once ebitcoin has downloaded all block headers of a block chain for
the first time.

Compaction can also be triggered by CouchDB itself. Read default.ini on how to
do this. This involves copying some sections to local.ini as it is not
recommended to change default.ini directly.

Logfiles
--------

ecoinpool keeps a set of logfiles in a folder called "log". They are divided in
categories. Each file will auto-rotate if its exceeds reaches 1MB. Some messages
are also written to stdout. All logging aspects can be configured in
`apps/ecoinpool/priv/log4erl.conf` and `apps/ebitcoin/priv/log4erl.conf`.

License
-------

ecoinpool is licensed under the GNU General Public License.
See the LICENSE file for details.
