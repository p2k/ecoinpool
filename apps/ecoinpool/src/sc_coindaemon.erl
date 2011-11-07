
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

-module(sc_coindaemon).
-behaviour(gen_coindaemon).
-behaviour(gen_server).

-include("ecoinpool_workunit.hrl").

-export([start_link/2, getwork_method/0, sendwork_method/0, share_target/0, get_workunit/1, encode_workunit/1, analyze_result/1, make_reply/1, send_result/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    url,
    auth,
    timer,
    last_getwork,
    getwork_data
}).

-record(sc_data, {
    version,
    hash_prev_block,
    hash_merkle_root,
    block_num,
    time,
    nonce1,
    nonce2,
    nonce3,
    nonce4,
    miner_id,
    bits
}).

%% ===================================================================
%% Gen_CoinDaemon API
%% ===================================================================

start_link(SubpoolId, Config) ->
    gen_server:start_link(?MODULE, [SubpoolId, Config], []).

getwork_method() ->
    sc_getwork.

sendwork_method() ->
    sc_testwork.

share_target() ->
    <<16#00007fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff:256>>.

get_workunit(PID) ->
    gen_server:call(PID, get_workunit).

encode_workunit(#workunit{target=Target, data=Data}) ->
    HexTarget = ecoinpool_util:bin_to_hexbin(Target),
    {[
        {<<"data">>, ecoinpool_util:bin_to_hexbin(Data)},
        {<<"target_share">>, <<"0x00007fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff">>},
        {<<"target_real">>, <<"0x", HexTarget/bytes>>}
    ]}.

analyze_result([Data]) when is_binary(Data), byte_size(Data) > 0, byte_size(Data) rem 256 =:= 0 ->
    analyze_result(Data, []);
analyze_result(_) ->
    error.

make_reply(Items) ->
    WorkEntries = lists:map(
        fun
            (invalid) ->
                {[
                    {<<"share_valid">>, false},
                    {<<"block_valid">>, false},
                    {<<"block_hash">>, <<"0000000000000000000000000000000000000000000000000000000000000000">>}
                ]};
            (BHash) ->
                {[
                    {<<"share_valid">>, true},
                    {<<"block_valid">>, false},
                    {<<"block_hash">>, ecoinpool_util:bin_to_hexbin(BHash)}
                ]}
        end,
        Items
    ),
    {[
        {<<"work">>, WorkEntries}
    ]}.

send_result(PID, BData) ->
    gen_server:call(PID, {send_result, BData}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    io:format("SC CoinDaemin starting~n"),
    
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, 8555),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(proplists:get_value(pass, Config, <<"pass">>)),
    
    {ok, Timer} = timer:send_interval(200, poll_daemon), % Always poll 5 times per second
    {ok, #state{subpool=SubpoolId, url=URL, auth={User, Pass}, timer=Timer}}.

handle_call(get_workunit, _From, State) ->
    {Result, WorkunitOrMessage, NewState} = getwork_with_state(State, true),
    {reply, {Result, WorkunitOrMessage}, NewState};

handle_call({send_result, BData}, _From, State=#state{url=URL, auth=Auth}) ->
    try
        {reply, sendwork(URL, Auth, BData), State}
    catch error:_ ->
        {reply, {error, <<"exception in sc_coindaemon:sendwork/3">>}, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State=#state{subpool=SubpoolId}) ->
    case getwork_with_state(State, false) of
        {error, Reason, NState} ->
            case Reason of
                no_new_block -> ok;
                _ -> io:format("exception in sc_coindaemon-poll_daemon: ~p~n", Reason)
            end,
            {noreply, NState};
        {Result, Workunit, NState} ->
            case Result of
                newblock -> ecoinpool_server:new_block_detected(SubpoolId);
                _ -> ok
            end,
            ecoinpool_server:store_workunit(SubpoolId, Workunit),
            {noreply, NState}
    end;

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer=Timer}) ->
    timer:cancel(Timer),
    io:format("SC CoinDaemon stopping~n"),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

analyze_result(<<>>, Acc) ->
    Acc;
analyze_result(<<Data:256/bytes, Remainder/bytes>>, Acc) ->
    case catch ecoinpool_util:hexbin_to_bin(Data) of
        {'EXIT', _} ->
            error;
        BData ->
            SCData = decode_sc_data(BData),
            WorkunitId = workunit_id_from_sc_data(SCData),
            Hash = ecoinpool_hash:rs_hash(BData),
            analyze_result(Remainder, Acc ++ [{WorkunitId, Hash, BData}])
    end.

send_req(URL, Auth, PostData) ->
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    ibrowse:send_req(URL, [{"User-Agent", "ecoinpool/" ++ VSN}, {"Accept", "application/json"}], post, PostData, [{basic_auth, Auth}, {content_type, "application/json"}]).

check_getwork_now(_, #state{last_getwork=undefined}) ->
    true;
check_getwork_now(_, #state{getwork_data=undefined}) ->
    true;
check_getwork_now(Now, #state{url=URL, auth=Auth, last_getwork=LastGetwork, getwork_data=SCData}) ->
    case timer:now_diff(Now, LastGetwork) of
        Diff when Diff < 200000 -> % Prevent rpc call if less than 200ms passed
            false;
        Diff when Diff > 20000000 -> % Force block load every 20s
            true;
        _ ->
            case send_req(URL, Auth, "{\"method\":\"getblocknumber\"}") of
                {ok, "200", _ResponseHeaders, ResponseBody} ->
                    {Body} = ejson:decode(ResponseBody),
                    BlockNum = proplists:get_value(<<"result">>, Body) + 1,
                    SCData#sc_data.block_num =/= BlockNum;
                _ ->
                    true
            end
    end.

getwork_with_state(State=#state{url=URL, auth=Auth, getwork_data=OldSCData}, Extrapolate) ->
    Now = erlang:now(),
    case check_getwork_now(Now, State) of
        true -> % Actually fetch work
            try
                case getwork(URL, Auth) of
                    {ok, SCData=#sc_data{block_num=BlockNum}} ->
                        OldBlockNum = case OldSCData of
                            undefined -> undefined;
                            #sc_data{block_num=BN} -> BN
                        end,
                        Result = case OldBlockNum of
                            undefined ->
                                ok;
                            BlockNum -> % Note: bound variable
                                ok;
                            _ ->
                                newblock % New block alarm!
                        end,
                        {Result, make_workunit(SCData), State#state{last_getwork=Now, getwork_data=SCData}};
                    {error, Reason} ->
                        {error, Reason, State}
                end
            catch error:_ ->
                {error, <<"exception in sc_coindaemon:getwork/2">>, State}
            end;
        _ -> % Extrapolate work or report no new block
            case Extrapolate of
                true ->
                    SCData = OldSCData#sc_data{nonce2 = OldSCData#sc_data.nonce2 + 16#00001000}, % Increase Nonce2 (starting at bit 12)
                    Workunit = make_workunit(SCData),
                    {ok, Workunit, State#state{getwork_data=SCData}};
                _ ->
                    {error, no_new_block, State}
            end
    end.

getwork(URL, Auth) ->
    case send_req(URL, Auth, "{\"method\":\"sc_getwork\"}") of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            {Result} = proplists:get_value(<<"result">>, Body),
            Data = proplists:get_value(<<"data">>, Result),
            BData = ecoinpool_util:hexbin_to_bin(Data),
            {ok, decode_sc_data(BData)};
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("getwork: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

sendwork(URL, Auth, BData) ->
    HexData = ecoinpool_util:list_to_hexstr(binary:bin_to_list(BData)),
    PostData = "{\"method\":\"sc_testwork\",\"params\":[\"" ++ HexData ++ "\"]}",
    case send_req(URL, Auth, PostData) of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            {Reply} = proplists:get_value(<<"result">>, Body),
            [{Work}] = proplists:get_value(<<"work">>, Reply),
            case proplists:get_value(<<"share_valid">>, Work) of
                true ->
                    accepted;
                _ ->
                    rejected
            end;
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("sendwork: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

decode_sc_data(SCData) ->
    <<
        Version:32/little,
        HashPrevBlock:32/bytes,
        HashMerkleRoot:32/bytes,
        BlockNum:64/little,
        Time:64/little,
        Nonce1:64/unsigned-little,
        Nonce2:64/unsigned-little,
        Nonce3:64/unsigned-little,
        Nonce4:32/unsigned-little,
        MinerId:12/bytes,
        Bits:32/little
    >> = SCData,
    
    #sc_data{version=Version,
        hash_prev_block=HashPrevBlock,
        hash_merkle_root=HashMerkleRoot,
        block_num=BlockNum,
        time=Time,
        nonce1=Nonce1,
        nonce2=Nonce2,
        nonce3=Nonce3,
        nonce4=Nonce4,
        miner_id=MinerId,
        bits=Bits}.

encode_sc_data(SCData) ->
    #sc_data{version=Version,
        hash_prev_block=HashPrevBlock,
        hash_merkle_root=HashMerkleRoot,
        block_num=BlockNum,
        time=Time,
        nonce1=Nonce1,
        nonce2=Nonce2,
        nonce3=Nonce3,
        nonce4=Nonce4,
        miner_id=MinerId,
        bits=Bits} = SCData,
    
    <<
        Version:32/little,
        HashPrevBlock:32/bytes,
        HashMerkleRoot:32/bytes,
        BlockNum:64/little,
        Time:64/little,
        Nonce1:64/unsigned-little,
        Nonce2:64/unsigned-little,
        Nonce3:64/unsigned-little,
        Nonce4:32/unsigned-little,
        MinerId:12/bytes,
        Bits:32/little
    >>.

workunit_id_from_sc_data(#sc_data{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot, nonce2=Nonce2}) ->
    Nonce2Masked = Nonce2 band 16#ffffffff,
    Data = <<HashPrevBlock/bytes, HashMerkleRoot/bytes, Nonce2Masked:64/unsigned-little>>,
    crypto:sha(Data).

make_workunit(SCData=#sc_data{bits=Bits, block_num=BlockNum}) ->
    BData = encode_sc_data(SCData),
    WUId = workunit_id_from_sc_data(SCData),
    Target = ecoinpool_util:bits_to_target(Bits),
    #workunit{id=WUId, target=Target, block_num=BlockNum, data=BData}.
