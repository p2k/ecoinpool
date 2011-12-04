#!/bin/bash

./rebar compile skip_deps=true || exit 1

export ERL_LIBS="deps:apps"

erl -sasl errlog_type error -smp enable -sname ebitcoin_test -s ebitcoin_test_launch start

# Use this function for hot code reloading while testing:
# Reload = fun (Module) -> true = code:soft_purge(Module), {module, Module} = code:load_file(Module), ok end.
