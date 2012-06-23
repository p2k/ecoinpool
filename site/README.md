
## ecoinpool Built-in Web Frontend ##

This folder contains the source code for the built-in web frontend of ecoinpool
and ebitcoin. It consists of several JavaScript files, template files, a
stylesheet and other resources which are combined into one design document
called "site".

In order to build the site design documents, you need a copy of
[closure compiler](http://code.google.com/intl/de-DE/closure/compiler/). Place
or symlink the compiler.jar into this folder.

Secondly, get [Sass](http://sass-lang.com/), a cascading style sheet compiler.
The `sass` executable has to be in your `PATH`. You also need
[compass](http://compass-style.org/), an enhancement library for sass.

You should also have `escript` in your `PATH` which usually comes with your
Erlang installation.

Finally run `make`, then `make install`. This will copy the resulting
`ecoinpool_site.json` file to `../apps/ecoinpool/priv/main_db_site.json` and
`ebitcoin_site.json` to `../apps/ebitcoin/priv/main_db_site.json`.

Currently, no version checks are done, so if you make changes (or pull my
changes from the GIT repository) you have to update the site design document
manually on CouchDB. There is a helper function available that will do this on
your behalf. Go to your ecoinpool console and enter:

    ecoinpool_db:update_site().
    ebitcoin_db:update_site().
