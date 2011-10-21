#!/bin/bash

rebar compile || exit 1

export ERL_LIBS="deps:apps"

erl -sasl errlog_type error -ecoinpool db_options '[{basic_auth, {"ecoinpool", "localtest"}}]' -smp enable -sname ecoinpool_test -s ecoinpool_test_launch start

# Use this function for hot code reloading while testing:
# Reload = fun (Module) -> true = code:soft_purge(Module), {module, Module} = code:load_file(Module), ok end.
