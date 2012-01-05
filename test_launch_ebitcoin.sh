#!/bin/bash

# This file only starts the ebitcoin part of ecoinpool for testing.
# Do not start both test_launch.sh and test_launch_ebitcoin.sh at the same time
# as test_launch.sh already launches ebitcoin along with ecoinpool!

./rebar compile skip_deps=true || exit 1

export ERL_LIBS="deps:apps"

erl -config test_launch -smp enable -sname ebitcoin_test -s ebitcoin_test_launch start

# Use this function for hot code reloading while testing:
# Reload = fun (Module) -> true = code:soft_purge(Module), {module, Module} = code:load_file(Module), ok end.
