
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

ecoinpool supports Bitcoin, Bitcoin+Namecoin (merged), Litecoin and Fairbrix.

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
do that, copy `test_launch.config.example` to `test_launch.config`, open it in
your favorite text editor and follow the instructions. Ignore the section about
the MySQL Replicator for now (full documentation for that has not been written
yet).

In case you wonder where to configure the aspects of a pool server, this is done
completely through CouchDB and/or the web frontend of ecoinpool. We'll get to
this right now.

Start up ecoinpool with `./test_launch.sh` - if everything's alright you should
see a welcome banner. The software does not daemonize in this beta version. If
you want to be able to close your console and keep the server running, you might
want to try [GNU Screen](http://www.gnu.org/software/screen/) like this:
`screen -D -R -S ecoinpool_test ./test_launch.sh`

> It might be worth knowing that you are on an Erlang console now. You can
> enter some commands and evaluate expressions (not covered in this readme).
> All console commands end with a period followed by a newline.

If you like to stop ecoinpool, you can quit via Ctrl+G and entering "q" at the
prompt. Alternatively you can hit Ctrl+C and enter "a" or simply kill the
process. There is no shutdown procedure required to be run, it's perfectly safe
to kill the process at any time. This is called "crash-only design". If you
still want to exit ecoinpool gracefully (which, as a little motivation, will
send "Server Terminating" as an error message to connected clients) enter `q().`
at the console.

> At this point you might want to configure ebitcoin first. ebitcoin is the
> block chain monitor/explorer which comes with ecoinpool as an add-on. It
> enables ecoinpool to listen for block changes instead of polling for the
> block number five times per second. See the section about "ebitcoin" below.

After you started ecoinpool, head over to the main site at
`http://<your domain>:5984/ecoinpool/_design/site/_show/home`. It should say
"This server has been freshly installed and is not configured yet. Fix this.". In
case you're no longer logged in on CouchDB (ecoinpool uses CouchDB's user and
authentication system), do so by clicking "Login" on the lower right corner. The
"Fix this" link will only appear for an admin user. Click it now and you will
see the Subpool configuration page.

First, choose the chain type for your pool, then enter a database name e.g.
"btc-pool". Make sure to use a different database name than you used for ebitcoin.
Next, you can optionally enter a display name which will be shown on the "Home"
page instead of the database name.

The "Port" setting denotes the port to which the miners should connect to;
ecoinpool will start listening for RPC requests on this port once the Subpool is
activated. Set it to 8888 if you don't know which port to choose.

The "Round" setting controls if a round number should be stored along with the
shares. On every candidate share (i.e. a share which potentially solves the
block) the round number is increased, if enabled. Enter a start value into the
text field if you want to use this feature.

The next two fields control ebitcoin's work caching behaviour. If you're just in
for a quick test, a cache size of 5 is enough. In other cases, the default value
of 20 usually fits all needs for heavy load. ecoinpool is constantly trying to
refill the cache as fast as possible and even when the cache runs empty or is
disabled it will stay fairly responsive. Be aware that the cache is completely
discarded on a block change and subsequently refilled, so don't set this value
too high. You can examine the server.log if you want to find an optimal value
yourself. Remember, the cache is just a way to deal with simultanous requests.
The maximum work age is the time in seconds until cached work will be discarded
(this is _not_ the time a miner has to send in valid work). Usually the default
is fine, if you're running a pool this won't happen that often anyway.

Next is the CoinDaemon configuration. The options you can set here depend on the
selected chain type. Daemons which support local work creation through the
`getmemorypool` call will have two extra fields "Pay To" and "Tag". The former
will override the default payout address on block solves; if you leave it
empty, ecoinpool will create an account called "ecoinpool" via RPC call and use
this one for payout. The other field allows you to add an arbitrary string to
the coinbase (max. 20 characters) which will be appended to "eco@". E.g. if you
set it to "ozco.in", the coinbase will start with "eco@ozco.in" (greetings fly
out to Graet and his team). If you leave it empty, the coinbase will start with
just "eco" as a default.

When the Daemon also supports the ebitcoin add-on, another field
"ebitcoin Client" will be displayed. It allows to choose from a list of
appropriate clients, identified by their database name.

Following the CoinDaemon configuration are the Aux Pool settings. These are used
for merged mining (only for Bitcoin), choose the desired chain from the list
(currently only NameCoin) and fill out the other fields just like for the main
pool. The AuxDaemon configuration panel also behaves in the same way as for the
CoinDaemon.

Hit "Save Configuration" above when you're finished with everything. Finally
click "Activate Subpool" after the page reloaded and your pool is running.
Reward yourself with cake and a hot beverage of your choice for reading this
far and getting the thing to run.

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
of the supported block chains and enter a database name for that chain. You need
only one client per chain, so choose a generic name like "btc-chain"; make sure
not to use the database name of an existing Subpool. After that, you can
optionally enter a display name which will be shown on the "Home" page instead
of the database name. Lastly, you can change the host and port of the daemon to
which ebitcoin will connect to, but for most cases, the defaults will do.

> Be aware that ebitcoin wants to connect to the peer-to-peer port of your
> daemon, not the RPC port. Also, ebitcoin will "believe" everything the
> daemon throws at it, no verification is done. That's why it has to be a
> trusted daemon preferably running on localhost.

Hit "Save Configuration" when you're finished. Finally click "Activate Client"
after the page reloaded and ebitcoin will start loading the block chain into
its own database. This will take some minutes depending on the chain size. You
can follow the process on the console or by looking at the logfiles. Note that
block monitoring will not function correctly until the complete chain has been
synchronized.

To use a client with ecoinpool, open the Subpool via ecoinpool's web interface.
On the configuration tab you can select an ebitcoin client from within the
CoinDaemon and the AuxDaemon configuration panel. Only compatible clients will
be displayed.

Technical information: In the current implementation, ebitcoin will only store
block headers (for Namecoin, this includes the aux proof-of-work).

Troubleshooting: Too Many Open Files (Linux)
--------------------------------------------

While testing the software on a larger pool (big thanks to WKNiGHT of Elitist
Jerks) both CouchDB and ecoinpool were pushed beyond the system limits of open
file descriptors, resulting in crashes about `{error,emfile}`. This happens
because one file descriptor is required per connection and the default setting
is 1024. You can check this, assuming your shell is bash, by running `ulimit -n`.
Additionally, there is a kernel-level limit of file descriptors which you can
see with `cat /proc/sys/fs/file-max`.

To temporarily increase the number of descriptors on the kernel-level you could
run `echo 65535 > /proc/sys/fs/file-max` as root (increasing the limit to 65535
in this example). To make the change survive across reboots, edit
`/etc/sysctl.conf` and add a line `fs.file-max = 65535`. You may want to set
this number even higher, depending on your server load.

For increasing the number of descriptors for the CouchDB and ecoinpool user,
you have to edit `/etc/security/limits.conf` or `/etc/limits.conf`, depending on
your linux distribution. You can either add a line `* - nofile 65535` to set
this globally for all linux users or add a line for each user replacing the `*`
with a username, e.g. `couchdb - nofile 65535` and `p2k - nofile 65535`. To
make these changes take effect, you have to logout and login again. If couchdb
was running, restart it too.

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
