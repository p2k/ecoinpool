
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

-module(btc_coindaemon).
-behaviour(gen_coindaemon).
-behaviour(gen_server).

-include("ecoinpool_workunit.hrl").
-include("btc_protocol_records.hrl").

-export([start_link/2, getwork_method/0, sendwork_method/0, share_target/0, post_workunit/1, encode_workunit/1, analyze_result/1, make_reply/1, send_result/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    url,
    auth,
    timer,
    block_num,
    last_fetch,
    prev_block_hash,
    transactions
}).

%% ===================================================================
%% Gen_CoinDaemon API
%% ===================================================================

start_link(SubpoolId, Config) ->
    gen_server:start_link(?MODULE, [SubpoolId, Config], []).

getwork_method() ->
    getwork.

sendwork_method() ->
    getwork.

share_target() ->
    <<16#00000000ffff0000000000000000000000000000000000000000000000000000:256>>.

post_workunit(PID) ->
    gen_server:cast(PID, post_workunit).

encode_workunit(#workunit{data=Data}) ->
    HexData = ecoinpool_util:bin_to_hexbin(ecoinpool_util:endian_swap(Data)),
    Midstate = ecoinpool_hash:sha256_midstate(Data),
    {[
        {<<"data">>, <<HexData/binary, "000000800000000000000000000000000000000000000000000000000000000000000000000000000000000080020000">>},
        {<<"midstate">>, ecoinpool_util:bin_to_hexbin(Midstate)},
        {<<"hash1">>, <<"00000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000010000">>},
        {<<"target">>, <<"0000000000000000000000000000000000000000000000000000ffff00000000">>}
    ]}.

analyze_result([<<Data:160/bytes, _/binary>>]) ->
    case catch ecoinpool_util:hexbin_to_bin(Data) of
        {'EXIT', _} ->
            error;
        BDataBigEndian ->
            BData = ecoinpool_util:endian_swap(BDataBigEndian),
            BTCHeader = btc_protocol:decode_btc_header(BData),
            WorkunitId = workunit_id_from_btc_header(BTCHeader),
            Hash = ecoinpool_hash:dsha256_hash(BData),
            [{WorkunitId, Hash, BData}]
    end;
analyze_result(_) ->
    error.

make_reply([invalid]) ->
    false;
make_reply([_]) ->
    true.

send_result(PID, BData) ->
    gen_server:call(PID, {send_result, BData}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    io:format("BTC CoinDaemin starting~n"),
    
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, 8332),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(proplists:get_value(pass, Config, <<"pass">>)),
    
    %if no payout address: getaddressesbyaccount Generated & getnewaddress Generated
    
    {ok, Timer} = timer:send_interval(200, poll_daemon), % Always poll 5 times per second
    {ok, #state{subpool=SubpoolId, url=URL, auth={User, Pass}, timer=Timer}}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State=#state{subpool=SubpoolId}) ->
    %getblocknumber
    {noreply, State};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer=Timer}) ->
    timer:cancel(Timer),
    io:format("BTC CoinDaemon stopping~n"),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

workunit_id_from_btc_header(#btc_header{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot}) ->
    Data = <<HashPrevBlock/bytes, HashMerkleRoot/bytes>>,
    crypto:sha(Data).
