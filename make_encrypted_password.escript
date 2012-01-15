#!/usr/bin/env escript
%%! -pa apps/ecoinpool/ebin

main(_) ->
    {ok, [Config]} = file:consult("test_launch.config"),
    EcoinpoolConfig = proplists:get_value(ecoinpool, Config),
    BFSecret = proplists:get_value(blowfish_secret, EcoinpoolConfig),
    PlainWithNL = io:get_line("Enter a password: "),
    Plain = list_to_binary(lists:sublist(PlainWithNL, length(PlainWithNL)-1)),
    {EncProps} = ecoinpool_util:make_json_password(BFSecret, Plain, random),
    io:format("{\"c\":\"~s\",\"i\":\"~s\"}~n", [proplists:get_value(<<"c">>, EncProps), proplists:get_value(<<"i">>, EncProps)]).
