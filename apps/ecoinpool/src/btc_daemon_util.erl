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

-module(btc_daemon_util).

-include("ecoinpool_workunit.hrl").
-include("btc_daemon_util.hrl").
-include("../ebitcoin/include/btc_protocol_records.hrl").

-compile(export_all).

encode_workunit(#workunit{data=Data}, MiningExtensions, HexTarget) ->
    HexData = ecoinpool_util:bin_to_hexbin(ecoinpool_util:endian_swap(Data)),
    case lists:member(midstate, MiningExtensions) of
        true ->
            {[
                {<<"data">>, <<HexData/binary, "000000800000000000000000000000000000000000000000000000000000000000000000000000000000000080020000">>},
                {<<"target">>, HexTarget}
            ]};
        _ ->
            Midstate = ecoinpool_hash:sha256_midstate(Data),
            {[
                {<<"data">>, <<HexData/binary, "000000800000000000000000000000000000000000000000000000000000000000000000000000000000000080020000">>},
                {<<"midstate">>, ecoinpool_util:bin_to_hexbin(Midstate)},
                {<<"hash1">>, <<"00000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000010000">>},
                {<<"target">>, HexTarget}
            ]}
    end.

analyze_result(<<Data:160/bytes, _/binary>>, HashFun) ->
    case catch ecoinpool_util:hexbin_to_bin(Data) of
        {'EXIT', _} ->
            error;
        BDataBigEndian ->
            BData = ecoinpool_util:endian_swap(BDataBigEndian),
            {Header, <<>>} = btc_protocol:decode_header(BData),
            WorkunitId = workunit_id_from_btc_header(Header),
            Hash = HashFun(BData),
            [{WorkunitId, Hash, BData}]
    end;
analyze_result(_, _) ->
    error.

parse_config(Config, DefaultPort) ->
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, DefaultPort),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(ecoinpool_util:parse_json_password(proplists:get_value(pass, Config, <<"pass">>))),
    
    CoinbaserConfig = ecoinpool_coinbaser:make_config(
        proplists:get_value(pay_to, Config),
        fun () -> {ok, DefaultAddress} = get_default_payout_address(URL, {User, Pass}), DefaultAddress end
    ),
    
    FullTag = case proplists:get_value(tag, Config) of
        Tag when not is_binary(Tag); byte_size(Tag) =:= 0 ->
            <<"eco">>;
        Tag when byte_size(Tag) < 24 ->
            <<"eco@", Tag/binary>>;
        Tag ->
            <<"eco@", Tag:24/binary>>
    end,
    
    EBtcId = proplists:get_value(ebitcoin_client_id, Config),
    
    {URL, {User, Pass}, CoinbaserConfig, FullTag, EBtcId}.

setup_blockchange_listener(undefined) ->
    {ok, _} = timer:send_interval(200, poll_daemon); % Always poll 5 times per second
setup_blockchange_listener(EBtcId) ->
    ebitcoin_client:add_blockchange_listener(EBtcId, self()).

load_or_create_state(SubpoolId, PoolType, AuxDaemon) ->
    StorageDir = ecoinpool_util:daemon_storage_dir(SubpoolId, lists:concat([PoolType, if AuxDaemon -> "_auxdaemon"; true -> "_coindaemon" end])),
    StoredState = case file:read_file(filename:join(StorageDir, "state.ext")) of
        {ok, Data} ->
            try
                #stored_state{} = binary_to_term(Data)
            catch
                error:_ -> #stored_state{}
            end;
        {error, _} ->
            #stored_state{}
    end,
    
    TxTbl = case ets:file2tab(binary_to_list(filename:join(StorageDir, "txtbl.ets")), [{verify, true}]) of
        {ok, Tab1} -> Tab1;
        {error, _} -> ets:new(txtbl, [set, protected])
    end,
    WorkTbl = case ets:file2tab(binary_to_list(filename:join(StorageDir, "worktbl.ets")), [{verify, true}]) of
        {ok, Tab2} -> Tab2;
        {error, _} -> ets:new(worktbl, [set, protected])
    end,
    
    {StoredState, TxTbl, WorkTbl}.

store_state(StoredState, SubpoolId, PoolType, TxTbl, WorkTbl, AuxDaemon) ->
    StorageDir = ecoinpool_util:daemon_storage_dir(SubpoolId, lists:concat([PoolType, if AuxDaemon -> "_auxdaemon"; true -> "_coindaemon" end])),
    Data = term_to_binary(StoredState),
    file:write_file(filename:join(StorageDir, "state.ext"), Data),
    ets:tab2file(TxTbl, binary_to_list(filename:join(StorageDir, "txtbl.ets")), [{extended_info, [object_count]}]),
    ets:tab2file(WorkTbl, binary_to_list(filename:join(StorageDir, "worktbl.ets")), [{extended_info, [object_count]}]).

send_result(BData, URL, Auth, WorkTbl, TxTbl) when is_binary(BData) ->
    {Header, <<>>} = btc_protocol:decode_header(BData),
    WorkunitId = workunit_id_from_btc_header(Header),
    send_result(WorkunitId, Header, URL, Auth, WorkTbl, TxTbl).

send_result(WorkunitId, Header=#btc_header{}, URL, Auth, WorkTbl, TxTbl) ->
    case ets:lookup(WorkTbl, WorkunitId) of
        [{_, CoinbaseTx, TxIndex, _}] ->
            [{_, Transactions}] = ets:lookup(TxTbl, TxIndex),
            try
                send_block(URL, Auth, Header, [CoinbaseTx | Transactions])
            catch error:_ ->
                {error, <<"exception in btc_daemon_util:send_block/5">>}
            end;
        [] ->
            rejected
    end.

send_aux_result(AuxHash, AuxPOW, URL, Auth, WorkTbl, TxTbl) ->
    case ets:lookup(WorkTbl, AuxHash) of
        [{_, CoinbaseTx, TxIndex, BasicHeader}] ->
            Header = BasicHeader#btc_header{auxpow=AuxPOW},
            [{_, Transactions}] = ets:lookup(TxTbl, TxIndex),
            try
                send_block(URL, Auth, Header, [CoinbaseTx | Transactions])
            catch error:_ ->
                {error, <<"exception in btc_daemon_util:send_block/5">>}
            end;
        [] ->
            rejected
    end.

get_first_tx_with_branches(WorkunitId, WorkTbl) ->
    case ets:lookup(WorkTbl, WorkunitId) of
        [{_, CoinbaseTx, _, FirstTreeBranches}] ->
            {ok, CoinbaseTx, FirstTreeBranches};
        [] ->
            {error, <<"unknown work">>}
    end.

make_workunit(BlockNum, OldCoinbaseTx, Memorypool, Tag, CoinbaserConfig, AuxWork, WorkTbl) ->
    #memorypool{hash_prev_block=HashPrevBlock, bits=Bits, tx_index=TxIndex, first_tree_branches=FirstTreeBranches} = Memorypool,
    % Create/update coinbase
    CoinbaseTx = case OldCoinbaseTx of
        undefined ->
            make_coinbase_tx(Memorypool, Tag, CoinbaserConfig, make_script_sig_trailer(AuxWork));
        _ ->
            increment_coinbase_extra_nonce(OldCoinbaseTx)
    end,
    % Create the header
    Header = make_btc_header(Memorypool, CoinbaseTx),
    % Create the workunit
    BHeader = btc_protocol:encode_main_header(Header),
    WUId = workunit_id_from_btc_header(Header),
    Target = ecoinpool_util:bits_to_target(Bits),
    Workunit = #workunit{id=WUId, ts=erlang:now(), target=Target, block_num=BlockNum, prev_block=HashPrevBlock, data=BHeader, aux_work=AuxWork},
    % Store the coinbase transaction and the transaction index for this workunit
    ets:insert(WorkTbl, {Workunit#workunit.id, btc_protocol:encode_tx(CoinbaseTx), TxIndex, FirstTreeBranches}),
    {Workunit, CoinbaseTx}.

make_auxwork(BlockNum, Memorypool, Tag, CoinbaserConfig, WorkTbl, HashFun) ->
    #memorypool{version=Version, hash_prev_block=HashPrevBlock, bits=Bits, tx_index=TxIndex} = Memorypool,
    16#100 = Version band 16#100,
    % Create coinbase
    CoinbaseTx = make_coinbase_tx(Memorypool, Tag, CoinbaserConfig, []),
    % Create the header
    Header = make_btc_header(Memorypool, CoinbaseTx),
    % Create auxwork
    BHeader = btc_protocol:encode_main_header(Header),
    AuxHash = HashFun(BHeader),
    Target = ecoinpool_util:bits_to_target(Bits),
    ChainId = (Version band 16#7fff0000) bsr 16,
    Auxwork = #auxwork{aux_hash=AuxHash, target=Target, chain_id=ChainId, block_num=BlockNum, prev_block=HashPrevBlock},
    % Store the coinbase transaction and the transaction index for this workunit
    ets:insert(WorkTbl, {AuxHash, btc_protocol:encode_tx(CoinbaseTx), TxIndex, Header}),
    Auxwork.

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

get_memory_pool(URL, Auth, TxTbl, OldMemorypool, MergedMining) ->
    case ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getmemorypool\"}") of
        {ok, "200", _ResponseHeaders, ResponseBody} ->
            {Body} = ejson:decode(ResponseBody),
            {Result} = proplists:get_value(<<"result">>, Body),
            Version = case proplists:get_value(<<"version">>, Result) of
                V when MergedMining -> V bor 16#100;
                V -> V
            end,
            
            HashPrevBlock = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"previousblockhash">>, Result)), % This already is big endian... curses...
            CoinbaseValue = proplists:get_value(<<"coinbasevalue">>, Result),
            Timestamp = proplists:get_value(<<"time">>, Result),
            <<Bits:32/unsigned>> = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"bits">>, Result)),
            Transactions = lists:map(fun ecoinpool_util:hexbin_to_bin/1, proplists:get_value(<<"transactions">>, Result)),
            
            TransactionHashes = lists:map(fun ecoinpool_hash:dsha256_hash/1, Transactions),
            FT = ecoinpool_hash:first_tree_branches_dsha256_hash(TransactionHashes),
            
            case OldMemorypool of
                #memorypool{version=Version, hash_prev_block=HashPrevBlock, bits=Bits, first_tree_branches=FT, coinbase_value=CoinbaseValue} ->
                    keep_old; % Nothing changed
                _ ->
                    TxIndex = ets:info(TxTbl, size),
                    ets:insert(TxTbl, {TxIndex, Transactions}),
                    log4erl:debug(daemon, "btc_daemon_util:get_memory_pool/4: New data received (#~b; ~b TX).", [TxIndex, length(Transactions)]),
                    #memorypool{
                        version = Version,
                        hash_prev_block = HashPrevBlock,
                        timestamp = Timestamp,
                        bits = Bits,
                        tx_index = TxIndex,
                        first_tree_branches = FT,
                        coinbase_value = CoinbaseValue
                    }
            end;
        {error, req_timedout} ->
            log4erl:warn(daemon, "btc_daemon_util:get_memory_pool/4: Request timed out!"),
            keep_old
    end.

-spec check_fetch_now(Now :: erlang:timestamp(), URL :: string(), Auth :: {string(), string()}, EBtcId :: binary() | undefined, BlockNum :: integer() | undefined | {pushed, integer()}, LastFetch :: erlang:timestamp() | undefined) -> {true, starting | timeout | error | {new_block, integer()}} | false.
check_fetch_now(_, _, _, _, _, undefined) ->
    {true, starting};
check_fetch_now(_, _, _, _, undefined, _) ->
    {true, starting};
check_fetch_now(_, _, _, _, {pushed, NewBlockNum}, _) ->
    {true, {new_block, NewBlockNum}};
check_fetch_now(Now, _, _, EBtcId, _, LastFetch) when is_binary(EBtcId) -> % Non-polling
    case timer:now_diff(Now, LastFetch) of
        Diff when Diff > 15000000 -> % Force data fetch every 15s
            {true, timeout};
        _ ->
            false
    end;
check_fetch_now(Now, URL, Auth, _, BlockNum, LastFetch) -> % Polling
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

fetch_work(SubpoolId, URL, Auth, EBtcId, OldBlockNum, LastFetch, TxTbl, WorkTbl, OldMemorypool, OldCoinbaseTx, AuxDaemonModule) ->
    Now = erlang:now(),
    case check_fetch_now(Now, URL, Auth, EBtcId, OldBlockNum, LastFetch) of
        false ->
            {OldBlockNum, LastFetch, OldMemorypool, OldCoinbaseTx};
        {true, Reason} ->
            case Reason of
                {new_block, _} ->
                    case AuxDaemonModule of
                        undefined -> ecoinpool_server:new_block_detected(SubpoolId);
                        _ -> ecoinpool_server:new_aux_block_detected(SubpoolId, AuxDaemonModule)
                    end,
                    ets:delete_all_objects(WorkTbl),
                    ets:delete_all_objects(TxTbl);
                _ ->
                    ok
            end,
            
            {Memorypool, CoinbaseTx} = case get_memory_pool(URL, Auth, TxTbl, OldMemorypool, AuxDaemonModule =/= undefined) of
                keep_old ->
                    {OldMemorypool, OldCoinbaseTx};
                NewMemorypool ->
                    {NewMemorypool, undefined}
            end,
            
            case Reason of
                {new_block, BlockNum} ->
                    {BlockNum, Now, Memorypool, CoinbaseTx};
                starting ->
                    TheBlockNum = case EBtcId of
                        undefined ->
                            get_block_number(URL, Auth);
                        _ ->
                            ebitcoin_client:last_block_num(EBtcId)
                    end,
                    {TheBlockNum, Now, Memorypool, CoinbaseTx};
                _ ->
                    {OldBlockNum, Now, Memorypool, CoinbaseTx}
            end
    end.

fetch_aux_work(undefined, _) ->
    undefined;
fetch_aux_work(MMM, OldAuxWork) ->
    case MMM:get_new_aux_work(OldAuxWork) of
        no_new_aux_work ->
            OldAuxWork;
        AuxWork=#auxwork{} ->
            log4erl:debug(daemon, "btc_daemon_util:fetch_aux_work/2: aux work changed."),
            AuxWork;
        {error, Message} ->
            log4erl:warn(daemon, "btc_daemon_util:fetch_aux_work/2: get_aux_work returned an error: ~p", [Message]),
            undefined
    end.

send_block(URL, Auth, Header, Transactions) ->
    BData = btc_protocol:encode_block(#btc_block{header=Header, txns=Transactions}),
    HexData = ecoinpool_util:list_to_hexstr(binary:bin_to_list(BData)),
    PostData = "{\"method\":\"getmemorypool\",\"params\":[\"" ++ HexData ++ "\"]}",
    log4erl:info(daemon, "btc_daemon_util:send_block/4: Sending upstream: ~s", [PostData]),
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
            {error, iolist_to_binary(io_lib:format("btc_daemon_util:send_block/4: Received HTTP ~s - Body: ~p", [Status, ResponseBody]))};
        {error, Reason} ->
            {error, Reason}
    end.

workunit_id_from_btc_header(#btc_header{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot}) ->
    Data = <<HashPrevBlock/bytes, HashMerkleRoot/bytes>>,
    crypto:sha(Data).

make_btc_header(#memorypool{version=Version, hash_prev_block=HashPrevBlock, timestamp=Timestamp, bits=Bits, first_tree_branches=FT}, CoinbaseTx) ->
    HashedTx = btc_protocol:get_hash(CoinbaseTx),
    HashMerkleRoot = ecoinpool_hash:fold_tree_branches_dsha256_hash(HashedTx, FT),
    #btc_header{version=Version, hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot, timestamp=Timestamp, bits=Bits}.

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

make_script_sig_trailer(undefined) ->
    [];
make_script_sig_trailer(#auxwork{aux_hash = <<AuxHash:256/big>>}) ->
    [<<250,190,109,109, AuxHash:256/little, 1,0,0,0,0,0,0,0>>].

flush_poll_daemon() ->
    receive
        poll_daemon -> flush_poll_daemon()
    after
        0 -> ok
    end.
