
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

-export([start_link/2, getwork_method/0, sendwork_method/0, get_workunit/1, encode_workunit/1, analyze_result/1, stale_reply/0, send_result/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    url,
    auth,
    timer,
    block_num
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

get_workunit(PID) ->
    gen_server:call(PID, get_workunit).

encode_workunit(#workunit{target=Target, data=Data}) ->
    {[
        {data, encode_sc_data(Data)},
        {target_share, <<"0x00007fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff">>},
        {target_real, binary:list_to_bin(io_lib:format("0x~64.16.0b", [Target]))}
    ]}.

analyze_result(Result) ->
    BinResult = ecoinpool_util:hexbin_to_bin(Result),
    SCData = decode_sc_data(BinResult),
    WorkunitId = workunit_id_from_sc_data(SCData),
    Hash = rs_hash:block_hash(BinResult),
    {WorkunitId, Hash}.

stale_reply() ->
    {[
        {work, [{[
            {share_valid, false},
            {block_valid, false},
            {block_hash, <<"0000000000000000000000000000000000000000000000000000000000000000">>}
        ]}]}
    ]}.

send_result(PID, Data) ->
    gen_server:call(PID, {send_result, Data}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    io:format("SC CoinDaemin starting~n"),
    
    rs_hash:block_hash_init(),
    
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, 8555),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(proplists:get_value(pass, Config, <<"pass">>)),
    
    {ok, Timer} = timer:send_interval(1000, poll_daemon),
    {ok, #state{subpool=SubpoolId, url=URL, auth={User, Pass}, timer=Timer}}.

handle_call(get_workunit, _From, State=#state{url=URL, auth=Auth, block_num=OldBlockNum}) ->
    try
        case getwork(URL, Auth) of
            {ok, Workunit=#workunit{data=#sc_data{block_num=BlockNum}}} ->
                case OldBlockNum of
                    undefined ->
                        {reply, {ok, Workunit}, State#state{block_num=BlockNum}};
                    BlockNum -> % Note: bound variable
                        {reply, {ok, Workunit}, State};
                    _ -> % New block alarm!
                        {reply, {newblock, Workunit}, State#state{block_num=BlockNum}}
                end;
            {error, Reason} ->
                {reply, {error, Reason}, State}
        end
    catch error:_ ->
        {reply, {error, <<"exception in sc_coindaemon:getwork/2">>}, State}
    end;

handle_call({send_result, Data}, _From, State=#state{url=URL, auth=Auth}) ->
    try
        {reply, sendwork(URL, Auth, Data), State}
    catch error:_ ->
        {reply, {error, <<"exception in sc_coindaemon:sendwork/3">>}, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State) ->

    {noreply, State};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{timer=Timer}) ->
    timer:cancel(Timer),
    io:format("SC CoinDaemin stopping~n"),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

getwork(URL, Auth) ->
    PostData = "{\"method\":\"sc_getwork\"}",
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    case ibrowse:send_req(URL, [{"User-Agent", "ecoinpool/" ++ VSN}, {"Accept", "application/json"}], post, PostData, [{basic_auth, Auth}, {content_type, "application/json"}]) of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            {Result} = proplists:get_value(<<"result">>, Body),
            HexSCData = proplists:get_value(<<"data">>, Result),
            SCData = decode_sc_data(HexSCData),
            WUId = workunit_id_from_sc_data(SCData),
            Target = ecoinpool_util:bits_to_target(SCData#sc_data.bits),
            {ok, #workunit{id=WUId, target=Target, data=SCData}};
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("getwork: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

sendwork(URL, Auth, Data) ->
    PostData = "{\"method\":\"sc_testwork\",\"params\":[\"" ++ binary:bin_to_list(Data) ++ "\"]}",
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    case ibrowse:send_req(URL, [{"User-Agent", "ecoinpool/" ++ VSN}, {"Accept", "application/json"}], post, PostData, [{basic_auth, Auth}, {content_type, "application/json"}]) of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            ReplyObj = proplists:get_value(<<"result">>, Body),
            {Reply} = ReplyObj,
            [{Work}] = proplists:get_value(<<"work">>, Reply),
            case proplists:get_value(<<"share_valid">>, Work) of
                true ->
                    case proplists:get_value(<<"block_valid">>, Work) of
                        true -> {winning, ReplyObj};
                        _ -> {valid, ReplyObj}
                    end;
                _ ->
                    {invalid, ReplyObj}
            end;
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("sendwork: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

decode_sc_data(SCData) when byte_size(SCData) =:= 128 ->
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
        bits=Bits};
decode_sc_data(HexSCData) ->
    decode_sc_data(ecoinpool_util:hexbin_to_bin(HexSCData)).

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
    
    ecoinpool_util:bin_to_hexbin(<<
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
    >>).

workunit_id_from_sc_data(#sc_data{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot, nonce2=Nonce2}) ->
    Data = <<HashPrevBlock/bytes, HashMerkleRoot/bytes, Nonce2:64/unsigned-little>>,
    crypto:sha(Data).
