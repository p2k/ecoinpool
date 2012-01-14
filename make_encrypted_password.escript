#!/usr/bin/env escript
%%! -pa apps/ecoinpool/ebin -pa deps/ejson/ebin

main(_) ->
    {ok, [Config]} = file:consult("test_launch.config"),
    EcoinpoolConfig = proplists:get_value(ecoinpool, Config),
    BFSecret = proplists:get_value(blowfish_secret, EcoinpoolConfig),
    application:set_env(ecoinpool, blowfish_secret, BFSecret),
    PlainWithNL = io:get_line("Enter a password: "),
    Plain = list_to_binary(lists:sublist(PlainWithNL, length(PlainWithNL)-1)),
    JPwd = ecoinpool_util:make_json_password(Plain),
    io:format("~s~n", [ejson:encode(JPwd)]).
