#!/bin/bash

./rebar compile skip_deps=true || exit 1

export ERL_LIBS="deps:apps"

erl +K true +P 262144 -config test_launch -smp enable -sname ecoinpool_test -s ecoinpool_test_launch start

# Use this function for hot code reloading while testing:
# Reload = fun (Module) -> true = code:soft_purge(Module), {module, Module} = code:load_file(Module), ok end.
