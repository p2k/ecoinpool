#!/bin/bash

# MySQL Notes:
# Minimum is MySQL 5.1.6 - please run the following queries as root:
# CREATE USER 'ecoinpool'@'localhost' IDENTIFIED BY 'localtest';
# GRANT TRIGGER ON `ecoinpool`.`pool_worker` TO 'ecoinpool'@'localhost';
# -- The database name is assumed to be `ecoinpool`, modify the above query and
# -- the .config files if you want to use a different name.

cd apps/ecoinpool_mysql_replicator
./rebar compile skip_deps=true || exit 1
cd ../..

export ERL_LIBS="deps:apps"

erl -config test_launch -smp enable -sname mysql_replicator_test -s ecoinpool_mysql_replicator_test_launch start

# Use this function for hot code reloading while testing:
# Reload = fun (Module) -> true = code:soft_purge(Module), {module, Module} = code:load_file(Module), ok end.

