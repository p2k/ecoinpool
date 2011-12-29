
## ecoinpool Built-in Web Frontend ##

This folder contains the source code for the built-in web frontend of ecoinpool.
It consists of several JavaScript files, a template file, a stylesheet and other
resources which are combined into one design document called "site".

In order to build the site design document, you need a copy of
[closure compiler](http://code.google.com/intl/de-DE/closure/compiler/). Place
or symlink the compiler.jar into this folder.

Secondly, get [Sass](http://sass-lang.com/), a cascading style sheet compiler.
The `sass` executable has to be in your `PATH`.

You should also have `escript` in your `PATH` which usually comes with your
Erlang installation.

Finally run "`make`", then move the resulting `main_db_site.json` file into
`apps/ecoinpool/priv`.

Currently, no version checks are done, so if you make changes you have to delete
the old site design document on CouchDB and restart the server or update it
manually on the database.
