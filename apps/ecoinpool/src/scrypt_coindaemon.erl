
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

-module(scrypt_coindaemon).
-behaviour(gen_coindaemon).
-behaviour(gen_server).

-ifdef(TEST).
-export([sample_header/0]).
-endif.

-include("ecoinpool_workunit.hrl").
-include("../ebitcoin/include/btc_protocol_records.hrl").

-include("gen_coindaemon_spec.hrl").

-export([
    start_link/2,
    getwork_method/0,
    sendwork_method/0,
    share_target/0,
    encode_workunit/2,
    analyze_result/1,
    make_reply/1,
    set_mmm/2,
    post_workunit/1,
    send_result/2,
    get_first_tx_with_branches/2
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    pool_type,
    url,
    auth,
    tag,
    coinbaser_config,
    
    ebtc_id,
    txtbl,
    worktbl,
    block_num,
    last_fetch,
    
    memorypool,
    coinbase_tx
}).

-record(memorypool, {
    hash_prev_block,
    timestamp,
    bits,
    tx_index,
    first_tree_branches,
    coinbase_value
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
    <<16#00007fffffffffffffffffffffffffffffffffffffffffffffffffffffffffff:256>>.

encode_workunit(#workunit{data=Data}, MiningExtensions) ->
    HexData = ecoinpool_util:bin_to_hexbin(ecoinpool_util:endian_swap(Data)),
    case lists:member(midstate, MiningExtensions) of
        true ->
            {[
                {<<"data">>, <<HexData/binary, "000000800000000000000000000000000000000000000000000000000000000000000000000000000000000080020000">>},
                {<<"target">>, <<"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f0000">>}
            ]};
        _ ->
            Midstate = ecoinpool_hash:sha256_midstate(Data),
            {[
                {<<"data">>, <<HexData/binary, "000000800000000000000000000000000000000000000000000000000000000000000000000000000000000080020000">>},
                {<<"midstate">>, ecoinpool_util:bin_to_hexbin(Midstate)},
                {<<"hash1">>, <<"00000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000010000">>},
                {<<"target">>, <<"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f0000">>}
            ]}
    end.

analyze_result([<<Data:160/bytes, _/binary>>]) ->
    case catch ecoinpool_util:hexbin_to_bin(Data) of
        {'EXIT', _} ->
            error;
        BDataBigEndian ->
            BData = ecoinpool_util:endian_swap(BDataBigEndian),
            {Header, <<>>} = btc_protocol:decode_header(BData),
            WorkunitId = workunit_id_from_btc_header(Header),
            Hash = ecoinpool_hash:scrypt_hash(BData),
            [{WorkunitId, Hash, BData}]
    end;
analyze_result(_) ->
    error.

make_reply([invalid]) ->
    false;
make_reply([_]) ->
    true.

set_mmm(_, _) ->
    {error, <<"unsupported">>}.

post_workunit(PID) ->
    gen_server:cast(PID, post_workunit).

send_result(PID, BData) ->
    gen_server:call(PID, {send_result, BData}).

get_first_tx_with_branches(_, _) ->
    {error, <<"unsupported">>}.

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    PoolType = proplists:get_value(pool_type, Config),
    log4erl:warn(daemon, "SCrypt-~p CoinDaemon starting...", [PoolType]),
    
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    DefaultPort = case PoolType of
        ltc -> 9332;
        fbx -> 8645
    end,
    Port = proplists:get_value(port, Config, DefaultPort),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(ecoinpool_util:parse_json_password(proplists:get_value(pass, Config, <<"pass">>))),
    
    CoinbaserConfig = ecoinpool_coinbaser:make_config(
        proplists:get_value(pay_to, Config),
        fun () -> {ok, DefaultAddress} = get_default_payout_address(URL, {User, Pass}), DefaultAddress end
    ),
    
    FullTag = case proplists:get_value(tag, Config) of
        Tag when is_binary(Tag), byte_size(Tag) > 0 ->
            <<"eco@", Tag/binary>>;
        _ ->
            <<"eco">>
    end,
    
    {TxTbl, WorkTbl} = case ecoinpool_sup:crash_transfer_ets({?MODULE, SubpoolId, txtbl}) of
        ok ->
            log4erl:info(daemon, "SCrypt-~p CoinDaemon is recovering from a crash", [PoolType]),
            ecoinpool_sup:crash_transfer_ets({?MODULE, SubpoolId, worktbl}),
            {undefined, undefined};
        error ->
            {ets:new(txtbl, [set, protected]), ets:new(worktbl, [set, protected])}
    end,
    
    EBtcId = case proplists:get_value(ebitcoin_client_id, Config) of
        undefined ->
            {ok, _} = timer:send_interval(200, poll_daemon), % Always poll 5 times per second
            undefined;
        Id ->
            ebitcoin_client:add_blockchange_listener(Id, self()),
            Id
    end,
    
    ecoinpool_server:coindaemon_ready(SubpoolId, self()),
    
    {ok, #state{subpool=SubpoolId, pool_type=PoolType, url=URL, auth={User, Pass}, tag=FullTag, coinbaser_config=CoinbaserConfig, ebtc_id=EBtcId, txtbl=TxTbl, worktbl=WorkTbl}}.

handle_call({send_result, BData}, _From, State=#state{url=URL, auth=Auth, worktbl=WorkTbl, txtbl=TxTbl}) ->
    {Header, <<>>} = btc_protocol:decode_header(BData),
    WorkunitId = workunit_id_from_btc_header(Header),
    case ets:lookup(WorkTbl, WorkunitId) of
        [{_, CoinbaseTx, TxIndex}] ->
            [{_, Transactions}] = ets:lookup(TxTbl, TxIndex),
            try
                {reply, send_block(URL, Auth, Header, [CoinbaseTx | Transactions]), State}
            catch error:_ ->
                {reply, {error, <<"exception in scrypt_coindaemon:send_block/3">>}, State}
            end;
        [] ->
            {reply, rejected, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(post_workunit, OldState) ->
    % Check if new work must be fetched
    State = fetch_work_with_state(OldState),
    % Extract state variables
    #state{subpool=SubpoolId, tag=Tag, coinbaser_config=CoinbaserConfig, worktbl=WorkTbl, block_num=BlockNum, memorypool=Memorypool, coinbase_tx=OldCoinbaseTx} = State,
    #memorypool{tx_index=TxIndex} = Memorypool,
    % Create/update coinbase
    CoinbaseTx = case OldCoinbaseTx of
        undefined ->
            make_coinbase_tx(Memorypool, Tag, CoinbaserConfig, []);
        _ ->
            increment_coinbase_extra_nonce(OldCoinbaseTx)
    end,
    % Create the header
    Header = make_btc_header(Memorypool, CoinbaseTx),
    % Create the workunit
    Workunit = make_workunit(Header, BlockNum),
    % Store the coinbase transaction and the transaction index for this workunit
    ets:insert(WorkTbl, {Workunit#workunit.id, CoinbaseTx, TxIndex}),
    % Send back
    ecoinpool_server:store_workunit(SubpoolId, Workunit),
    % Update state
    {noreply, State#state{coinbase_tx=CoinbaseTx}};

handle_cast({ebitcoin_blockchange, _, _, BlockNum}, State) ->
    {noreply, fetch_work_with_state(State#state{block_num={pushed, BlockNum + 1}})};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State) ->
    {noreply, fetch_work_with_state(State)};

handle_info(retry_post_workunit, State) ->
    handle_cast(post_workunit, State);

handle_info({'ETS-TRANSFER', TxTbl, _FromPid, {?MODULE, SubpoolId, txtbl}}, State=#state{subpool=SubpoolId}) ->
    {noreply, State#state{txtbl=TxTbl}};

handle_info({'ETS-TRANSFER', WorkTbl, _FromPid, {?MODULE, SubpoolId, worktbl}}, State=#state{subpool=SubpoolId}) ->
    {noreply, State#state{worktbl=WorkTbl}};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(Reason, #state{subpool=SubpoolId, pool_type=PoolType, txtbl=TxTbl, worktbl=WorkTbl}) ->
    case Reason of
        normal -> ok;
        shutdown -> ok;
        {shutdown, _} -> ok;
        _ ->
            CrashRepoPid = ecoinpool_sup:crash_repo_pid(),
            ets:give_away(TxTbl, CrashRepoPid, {?MODULE, SubpoolId, txtbl}),
            ets:give_away(WorkTbl, CrashRepoPid, {?MODULE, SubpoolId, worktbl})
    end,
    log4erl:warn(daemon, "SCrypt-~p CoinDaemon terminated.", [PoolType]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

get_default_payout_address(URL, Auth) ->
    case ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getaddressesbyaccount\",\"params\":[\"ecoinpool\"]}") of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            case proplists:get_value(<<"result">>, Body) of
                [] ->
                    case ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getnewaddress\",\"params\":[\"ecoinpool\"]}") of
                        {ok, "200", _ResponseHeaders2, ResponseBody2} ->
                            {Body2} = ejson:decode(ResponseBody2),
                            {ok, proplists:get_value(<<"result">>, Body2)};
                        {ok, Status, _ResponseHeaders, ResponseBody2} ->
                            {error, binary:list_to_bin(io_lib:format("getnewaddress: Received HTTP ~s - Body: ~p", [Status, ResponseBody2]))};
                        {error, Reason} ->
                            {error, Reason}
                    end;
                List ->
                    {ok, lists:last(List)}
            end;
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("getaddressesbyaccount: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

get_block_number(URL, Auth) ->
    {ok, "200", _ResponseHeaders, ResponseBody} = ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getblocknumber\"}"),
    {Body} = ejson:decode(ResponseBody),
    proplists:get_value(<<"result">>, Body) + 1.

get_memory_pool(URL, Auth, TxTbl, OldMemorypool) ->
    case ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getmemorypool\"}") of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            {Result} = proplists:get_value(<<"result">>, Body),
            1 = proplists:get_value(<<"version">>, Result),
            
            HashPrevBlock = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"previousblockhash">>, Result)), % This already is big endian... curses...
            CoinbaseValue = proplists:get_value(<<"coinbasevalue">>, Result),
            Timestamp = proplists:get_value(<<"time">>, Result),
            <<Bits:32/unsigned>> = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"bits">>, Result)),
            Transactions = lists:map(fun ecoinpool_util:hexbin_to_bin/1, proplists:get_value(<<"transactions">>, Result)),
            
            TransactionHashes = lists:map(fun ecoinpool_hash:dsha256_hash/1, Transactions),
            FT = ecoinpool_hash:first_tree_branches_dsha256_hash(TransactionHashes),
            
            case OldMemorypool of
                #memorypool{hash_prev_block=HashPrevBlock, bits=Bits, first_tree_branches=FT, coinbase_value=CoinbaseValue} ->
                    keep_old; % Nothing changed
                _ ->
                    TxIndex = ets:info(TxTbl, size),
                    ets:insert(TxTbl, {TxIndex, Transactions}),
                    log4erl:debug(daemon, "scrypt_coindaemon: get_memory_pool: New data received (#~b; ~b TX).", [TxIndex, length(Transactions)]),
                    #memorypool{
                        hash_prev_block = HashPrevBlock,
                        timestamp = Timestamp,
                        bits = Bits,
                        tx_index = TxIndex,
                        first_tree_branches = FT,
                        coinbase_value = CoinbaseValue
                    }
            end;
        {error, req_timedout} ->
            log4erl:warn(daemon, "scrypt_coindaemon: get_memory_pool: Request timed out!"),
            keep_old
    end.

check_fetch_now(_, #state{last_fetch=undefined}) ->
    {true, starting};
check_fetch_now(_, #state{block_num=undefined}) ->
    {true, starting};
check_fetch_now(Now, #state{ebtc_id=EBtcId, block_num=BlockNum, last_fetch=LastFetch}) when is_binary(EBtcId) -> % Non-polling
    case BlockNum of
        {pushed, NewBlockNum} ->
            {true, {new_block, NewBlockNum}};
        _ ->
            case timer:now_diff(Now, LastFetch) of
                Diff when Diff > 15000000 -> % Force data fetch every 15s
                    {true, timeout};
                _ ->
                    false
            end
    end;
check_fetch_now(Now, #state{url=URL, auth=Auth, block_num=BlockNum, last_fetch=LastFetch}) -> % Polling
    case timer:now_diff(Now, LastFetch) of
        Diff when Diff < 200000 -> % Prevent rpc call if less than 200ms passed
            false;
        Diff when Diff > 15000000 -> % Force data fetch every 15s
            {true, timeout};
        _ ->
            try
                case get_block_number(URL, Auth) of
                    BlockNum ->
                        false;
                    NewBlockNum ->
                        {true, {new_block, NewBlockNum}}
                end
            catch error:_ ->
                {true, error}
            end
    end.

fetch_work_with_state(State=#state{subpool=SubpoolId, url=URL, auth=Auth, ebtc_id=EBtcId, txtbl=TxTbl, worktbl=WorkTbl, memorypool=OldMemorypool, coinbase_tx=OldCoinbaseTx}) ->
    Now = erlang:now(),
    case check_fetch_now(Now, State) of
        false ->
            State;
        {true, Reason} ->
            case Reason of
                {new_block, _} ->
                    ecoinpool_server:new_block_detected(SubpoolId),
                    ets:delete_all_objects(WorkTbl),
                    ets:delete_all_objects(TxTbl);
                _ ->
                    ok
            end,
            
            {Memorypool, CoinbaseTx} = case get_memory_pool(URL, Auth, TxTbl, OldMemorypool) of
                keep_old ->
                    {OldMemorypool, OldCoinbaseTx};
                NewMemorypool ->
                    {NewMemorypool, undefined}
            end,
            
            case Reason of
                {new_block, BlockNum} ->
                    State#state{block_num=BlockNum, last_fetch=Now, memorypool=Memorypool, coinbase_tx=CoinbaseTx};
                starting ->
                    TheBlockNum = case EBtcId of
                        undefined ->
                            get_block_number(URL, Auth);
                        _ ->
                            ebitcoin_client:last_block_num(EBtcId)
                    end,
                    State#state{block_num=TheBlockNum, last_fetch=Now, memorypool=Memorypool, coinbase_tx=CoinbaseTx};
                _ ->
                    State#state{last_fetch=Now, memorypool=Memorypool, coinbase_tx=CoinbaseTx}
            end
    end.

send_block(URL, Auth, Header, Transactions) ->
    BData = btc_protocol:encode_block(#btc_block{header=Header, txns=Transactions}),
    HexData = ecoinpool_util:list_to_hexstr(binary:bin_to_list(BData)),
    PostData = "{\"method\":\"getmemorypool\",\"params\":[\"" ++ HexData ++ "\"]}",
    log4erl:info(daemon, "scrypt_coindaemon: Sending upstream: ~s", [PostData]),
    case ecoinpool_util:send_http_req(URL, Auth, PostData) of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            case proplists:get_value(<<"result">>, Body) of
                true ->
                    accepted;
                _ ->
                    rejected
            end;
        {ok, Status, _ResponseHeaders, ResponseBody} ->
            {error, binary:list_to_bin(io_lib:format("send_block: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

workunit_id_from_btc_header(#btc_header{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot}) ->
    Data = <<HashPrevBlock/bytes, HashMerkleRoot/bytes>>,
    crypto:sha(Data).

make_btc_header(#memorypool{hash_prev_block=HashPrevBlock, timestamp=Timestamp, bits=Bits, first_tree_branches=FT}, CoinbaseTx) ->
    HashedTx = btc_protocol:get_hash(CoinbaseTx),
    HashMerkleRoot = ecoinpool_hash:fold_tree_branches_dsha256_hash(HashedTx, FT),
    #btc_header{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot, timestamp=Timestamp, bits=Bits}.

make_coinbase_tx(#memorypool{timestamp=Timestamp, coinbase_value=CoinbaseValue}, Tag, CoinbaserConfig, ScriptSigTrailer) ->
    TxIn = #btc_tx_in{
        prev_output_hash = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
        prev_output_index = 16#ffffffff,
        signature_script = [Tag, Timestamp, 0 | ScriptSigTrailer]
    },
    TxOut = ecoinpool_coinbaser:run(CoinbaserConfig, CoinbaseValue),
    #btc_tx{tx_in=[TxIn], tx_out=TxOut}.

increment_coinbase_extra_nonce(Tx=#btc_tx{tx_in=[TxIn]}) ->
    #btc_tx_in{signature_script = [Tag, Timestamp, ExtraNonce | ScriptSigTrailer]} = TxIn,
    Tx#btc_tx{tx_in=[TxIn#btc_tx_in{signature_script = [Tag, Timestamp, ExtraNonce+1 | ScriptSigTrailer]}]}.

make_workunit(Header=#btc_header{bits=Bits, hash_prev_block=PrevBlock}, BlockNum) ->
    BHeader = btc_protocol:encode_main_header(Header),
    WUId = workunit_id_from_btc_header(Header),
    Target = ecoinpool_util:bits_to_target(Bits),
    #workunit{id=WUId, ts=erlang:now(), target=Target, block_num=BlockNum, prev_block=PrevBlock, data=BHeader}.

-ifdef(TEST).

sample_header() ->
    base64:decode(<<"AQAAAPYV9847T8a49h6Pia7bHQhSUHZQUzqeOxC5u8wwY58nn8qoZ0bh71LT7bPErYJZkg1Qm9BzYFyb8dWZg3Uqawa4F7tOp44BHQEtWdQ=">>).

-endif.
