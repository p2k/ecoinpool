
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ecoinpool.
%%
%% ecoinpool is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ecoinpool is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ecoinpool_coinbaser).

-include("../ebitcoin/include/btc_protocol_records.hrl").

-export([make_config/2, run/2]).

-type coinbaser_config() :: {default, DefaultPayTo :: binary()} | {cmd | tcp, DefaultPayTo :: binary(), Command :: string()}.

%% ===================================================================
%% API functions
%% ===================================================================

-spec make_config(Config :: {list()} | binary() | undefined, GetDefaultAddressFun :: fun(() -> binary())) -> coinbaser_config().
make_config(undefined, GetDefaultAddressFun) ->
    {default, btc_protocol:hash160_from_address(GetDefaultAddressFun())};
make_config(Address, _) when is_binary(Address) ->
    {default, btc_protocol:hash160_from_address(Address)};
make_config({CoinbaserProps}, GetDefaultAddressFun) ->
    DefaultPayTo = btc_protocol:hash160_from_address(case proplists:get_value(<<"default">>, CoinbaserProps) of
        Address when is_binary(Address) -> Address;
        _ -> GetDefaultAddressFun()
    end),
    case proplists:get_value(<<"cmd">>, CoinbaserProps) of
        Command when is_binary(Command) ->
            {cmd, DefaultPayTo, binary_to_list(Command)};
        _ ->
            case proplists:get_value(<<"tcp">>, CoinbaserProps) of
                HostPort when is_binary(HostPort) ->
                    {tcp, DefaultPayTo, binary_to_list(HostPort)};
                _ ->
                    {default, DefaultPayTo}
            end
    end.

-spec run(Config :: coinbaser_config(), CoinbaseValue :: integer()) -> [btc_tx_out()].
run({default, DefaultPayTo}, CoinbaseValue) ->
    [make_tx_out(CoinbaseValue, DefaultPayTo)];
run({cmd, DefaultPayTo, Command}, CoinbaseValue) ->
    PreparedCommand = re:replace(Command, "%d", integer_to_list(CoinbaseValue), [global, {return,list}]),
    try
        Port = open_port({spawn, PreparedCommand}, [{line, 256}, use_stdio, hide]),
        try
            get_destinations(Port, CoinbaseValue, DefaultPayTo)
        after
            case erlang:port_info(Port, id) of
                undefined -> true;
                _ -> port_close(Port)
            end
        end
    catch Type:Reason ->
        log4erl:error("Coinbaser command \"~s\" failed with ~p reason:~n~p", [PreparedCommand, Type, Reason]),
        run({default, DefaultPayTo}, CoinbaseValue)
    end;
run({tcp, DefaultPayTo, Command}, CoinbaseValue) ->
    try
        case string:tokens(Command, ":") of
            [Host, SPort] ->
                case catch list_to_integer(SPort) of
                    {'EXIT', _} ->
                        throw({"Bad definition of TCP coinbaser: \"~s\".", [Command]});
                    Port ->
                        case gen_tcp:connect(Host, Port, [list, {packet, line}, {exit_on_close, false}], 5000) of
                            {ok, Socket} ->
                                try
                                    gen_tcp:send(Socket, ["total: ", integer_to_list(CoinbaseValue), 10, 10]),
                                    get_destinations(Socket, CoinbaseValue, DefaultPayTo)
                                after
                                    receive {tcp_closed, Socket} -> ok after 0 -> ok end,
                                    gen_tcp:close(Socket)
                                end;
                            {error, EReason} ->
                                error(EReason)
                        end
                end;
            _ ->
                throw({"Bad definition of TCP coinbaser: \"~s\".", [Command]})
        end
    catch
        throw:{Msg, Params} ->
            log4erl:error(Msg, Params);
        Type:Reason ->
            case {Type, Reason} of
                {throw, {Msg, Params}} ->
                    log4erl:error(Msg, Params);
                _ ->
                    log4erl:error("TCP coinbaser \"~s\" failed with ~p reason:~n~p", [Command, Type, Reason])
            end,
            run({default, DefaultPayTo}, CoinbaseValue)
    end.

%% ===================================================================
%% Other functions
%% ===================================================================

get_destinations(PortOrSocket, CoinbaseValue, DefaultPayTo) ->
    NumberOfDests = receive
        {PortOrSocket, {data, {eol, SNumberOfDests}}} -> list_to_integer(SNumberOfDests);
        {tcp, PortOrSocket, SNumberOfDests} -> list_to_integer(string:strip(SNumberOfDests, right, 10))
    after
        5000 -> error(timeout)
    end,
    {CoinbaseValueLeft, TxOutList} = get_destinations_loop(PortOrSocket, NumberOfDests, CoinbaseValue, []),
    if
        CoinbaseValueLeft < 0 ->
            error(distributed_more_funds_than_available);
        CoinbaseValueLeft =:= 0 -> % No funds are left -> proceed
            TxOutList;
        true -> % Some funds are left -> pay to default address
            run({default, DefaultPayTo}, CoinbaseValueLeft) ++ TxOutList
    end.

get_destinations_loop(_, 0, CoinbaseValueLeft, TxOutAcc) ->
    {CoinbaseValueLeft, TxOutAcc};
get_destinations_loop(PortOrSocket, NumberOfDests, CoinbaseValueLeft, TxOutAcc) ->
    Value = receive
        {PortOrSocket, {data, {eol, SValue}}} -> list_to_integer(SValue);
        {tcp, PortOrSocket, SValue} -> list_to_integer(string:strip(SValue, right, 10))
    after
        2500 -> error(timeout)
    end,
    PayTo = receive
        {PortOrSocket, {data, {eol, Address}}} -> btc_protocol:hash160_from_address(Address);
        {tcp, PortOrSocket, Address} -> btc_protocol:hash160_from_address(string:strip(Address, right, 10))
    after
        2500 -> error(timeout)
    end,
    NewTxOutAcc = if
        Value < 0 ->
            error(negative_value_received);
        Value =:= 0 ->
            TxOutAcc;
        true ->
            TxOutAcc ++ [make_tx_out(Value, PayTo)]
    end,
    get_destinations_loop(PortOrSocket, NumberOfDests - 1, CoinbaseValueLeft - Value, NewTxOutAcc).

make_tx_out(Value, PayTo) ->
    #btc_tx_out{
        value = Value,
        pk_script = [op_dup, op_hash160, PayTo, op_equalverify, op_checksig]
    }.
