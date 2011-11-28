
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

-export([
    start_link/2,
    getwork_method/0,
    sendwork_method/0,
    share_target/0,
    encode_workunit/1,
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
    url,
    auth,
    tag,
    pay_to,
    
    mmm,
    
    timer,
    txtbl,
    block_num,
    last_fetch,
    
    memorypool,
    coinbase_tx,
    
    aux_work
}).

-record(memorypool, {
    hash_prev_block,
    timestamp,
    bits,
    transactions,
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
    <<16#00000000ffff0000000000000000000000000000000000000000000000000000:256>>.

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
            Header = btc_protocol:decode_header(BData),
            WorkunitId = workunit_id_from_btc_header(Header),
            Hash = ecoinpool_hash:dsha256_hash(BData),
            [{WorkunitId, Hash, BData}]
    end;
analyze_result(_) ->
    error.

make_reply([invalid]) ->
    false;
make_reply([_]) ->
    true.

set_mmm(PID, MMM) ->
    gen_server:cast(PID, {set_mmm, MMM}).

post_workunit(PID) ->
    gen_server:cast(PID, post_workunit).

send_result(PID, BData) ->
    gen_server:call(PID, {send_result, BData}).

get_first_tx_with_branches(PID, Workunit) ->
    gen_server:call(PID, {get_first_tx_with_branches, Workunit}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId, Config]) ->
    process_flag(trap_exit, true),
    io:format("BTC CoinDaemon starting~n"),
    
    Host = binary:bin_to_list(proplists:get_value(host, Config, <<"localhost">>)),
    Port = proplists:get_value(port, Config, 8332),
    URL = lists:flatten(io_lib:format("http://~s:~b/", [Host, Port])),
    User = binary:bin_to_list(proplists:get_value(user, Config, <<"user">>)),
    Pass = binary:bin_to_list(proplists:get_value(pass, Config, <<"pass">>)),
    
    PayTo = btc_protocol:hash160_from_address(case proplists:get_value(pay_to, Config) of
        undefined ->
            {ok, Address} = get_default_payout_address(URL, {User, Pass}),
            Address;
        Address ->
            Address
    end),
    
    FullTag = case proplists:get_value(tag, Config) of
        Tag when is_binary(Tag), byte_size(Tag) > 0 ->
            <<"ecoinpool@", Tag/binary>>;
        _ ->
            <<"ecoinpool">>
    end,
    
    TxTbl = ets:new(txtbl, [set, protected]),
    
    {ok, Timer} = timer:send_interval(200, poll_daemon), % Always poll 5 times per second
    {ok, #state{subpool=SubpoolId, url=URL, auth={User, Pass}, tag=FullTag, pay_to=PayTo, timer=Timer, txtbl=TxTbl}}.

handle_call({send_result, BData}, _From, State=#state{url=URL, auth=Auth, txtbl=TxTbl}) ->
    Header = btc_protocol:decode_header(BData),
    WorkunitId = workunit_id_from_btc_header(Header),
    case ets:lookup(TxTbl, WorkunitId) of
        [{_, Transactions, _}] ->
            try
                {reply, send_block(URL, Auth, Header, Transactions), State}
            catch error:_ ->
                {reply, {error, <<"exception in btc_coindaemon:send_block/3">>}, State}
            end;
        [] ->
            {reply, rejected, State}
    end;

handle_call({get_first_tx_with_branches, #workunit{id=WorkunitId}}, _From, State=#state{txtbl=TxTbl}) ->
    case ets:lookup(TxTbl, WorkunitId) of
        [{_, [CoinbaseTx|_], FirstTreeBranches}] ->
            FirstTreeBranchesLE = lists:map(fun ecoinpool_util:byte_reverse/1, FirstTreeBranches),
            {reply, {ok, CoinbaseTx, FirstTreeBranchesLE}, State};
        [] ->
            {reply, {error, <<"unknown work">>}, State}
    end;

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({set_mmm, MMM}, State) ->
    {noreply, State#state{mmm=MMM}};

handle_cast(post_workunit, OldState) ->
    % Check if new work must be fetched
    State = fetch_work_with_state(OldState),
    % Extract state variables
    #state{subpool=SubpoolId, tag=Tag, pay_to=PubkeyHash160, txtbl=TxTbl, block_num=BlockNum, memorypool=Memorypool, coinbase_tx=OldCoinbaseTx, aux_work=AuxWork} = State,
    #memorypool{transactions=Transactions, first_tree_branches=FirstTreeBranches} = Memorypool,
    % Create/update coinbase
    CoinbaseTx = case OldCoinbaseTx of
        undefined ->
            make_coinbase_tx(Memorypool, Tag, PubkeyHash160, make_script_sig_trailer(AuxWork));
        _ ->
            increment_coinbase_extra_nonce(OldCoinbaseTx)
    end,
    % Create the header
    Header = make_btc_header(Memorypool, CoinbaseTx),
    % Create the workunit
    Workunit = make_workunit(Header, BlockNum, AuxWork),
    % Store transactions for this workunit, including the coinbase transaction
    ets:insert(TxTbl, {Workunit#workunit.id, [CoinbaseTx | Transactions], FirstTreeBranches}),
    % Send back
    ecoinpool_server:store_workunit(SubpoolId, Workunit),
    % Update state
    {noreply, State#state{coinbase_tx=CoinbaseTx}};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(poll_daemon, State) ->
    {noreply, fetch_work_with_state(State)};

handle_info(retry_post_workunit, State) ->
    handle_cast(post_workunit, State);

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

get_memory_pool(URL, Auth) ->
    {ok, "200", _ResponseHeaders, ResponseBody} = ecoinpool_util:send_http_req(URL, Auth, "{\"method\":\"getmemorypool\"}"),
    {Body} = ejson:decode(ResponseBody),
    {Result} = proplists:get_value(<<"result">>, Body),
    1 = proplists:get_value(<<"version">>, Result),
    
    HashPrevBlock = ecoinpool_util:byte_reverse(ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"previousblockhash">>, Result))),
    CoinbaseValue = proplists:get_value(<<"coinbasevalue">>, Result),
    Timestamp = proplists:get_value(<<"time">>, Result),
    <<Bits:32/unsigned>> = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"bits">>, Result)),
    Transactions = lists:map(fun ecoinpool_util:hexbin_to_bin/1, proplists:get_value(<<"transactions">>, Result)),
    
    TransactionHashes = lists:map(fun ecoinpool_hash:dsha256_hash/1, Transactions),
    FT = ecoinpool_hash:first_tree_branches_dsha256_hash(TransactionHashes),
    
    #memorypool{
        hash_prev_block = HashPrevBlock,
        timestamp = Timestamp,
        bits = Bits,
        transactions = Transactions,
        first_tree_branches = FT,
        coinbase_value = CoinbaseValue
    }.

check_fetch_now(_, #state{last_fetch=undefined}) ->
    {true, starting};
check_fetch_now(_, #state{block_num=undefined}) ->
    {true, starting};
check_fetch_now(Now, #state{url=URL, auth=Auth, block_num=BlockNum, last_fetch=LastFetch}) ->
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

fetch_work_with_state(State=#state{subpool=SubpoolId, url=URL, auth=Auth, txtbl=TxTbl, memorypool=OldMemorypool, coinbase_tx=OldCoinbaseTx}) ->
    Now = erlang:now(),
    NewState = case check_fetch_now(Now, State) of
        false ->
            State;
        {true, Reason} ->
            case Reason of
                {new_block, _} ->
                    ecoinpool_server:new_block_detected(SubpoolId),
                    ets:delete_all_objects(TxTbl);
                _ ->
                    ok
            end,
            
            Memorypool = get_memory_pool(URL, Auth),
            CoinbaseTx = case memorypools_equivalent(OldMemorypool, Memorypool) of
                true ->
                    OldCoinbaseTx;
                _ ->
                    io:format("btc_coindaemon: fetch_work_with_state: memory pool changed!~n"),
                    undefined
            end,
            
            case Reason of
                {new_block, BlockNum} ->
                    State#state{block_num=BlockNum, last_fetch=Now, memorypool=Memorypool, coinbase_tx=CoinbaseTx};
                starting ->
                    State#state{block_num=get_block_number(URL, Auth), last_fetch=Now, memorypool=Memorypool, coinbase_tx=CoinbaseTx};
                _ ->
                    State#state{last_fetch=Now, memorypool=Memorypool, coinbase_tx=CoinbaseTx}
            end
    end,
    fetch_aux_work_with_state(NewState).

fetch_aux_work_with_state(State=#state{mmm=undefined, aux_work=undefined}) ->
    State;
fetch_aux_work_with_state(State=#state{mmm=undefined}) ->
    State#state{aux_work=undefined};
fetch_aux_work_with_state(State=#state{mmm=MMM, aux_work=OldAuxWork}) ->
    case MMM:get_new_aux_work(OldAuxWork) of
        no_new_aux_work ->
            State;
        AuxWork=#auxwork{} ->
            io:format("btc_coindaemon: fetch_aux_work_with_state: aux work changed!~n"),
            State#state{aux_work=AuxWork, coinbase_tx=undefined};
        {error, Message} ->
            io:format("btc_coindaemon: fetch_aux_work_with_state: Warning: get_aux_work returned an error: ~p~n", [Message]),
            State#state{aux_work=undefined}
    end.

send_block(URL, Auth, Header, Transactions) ->
    BData = btc_protocol:encode_block(#btc_block{header=Header, txns=Transactions}),
    HexData = ecoinpool_util:list_to_hexstr(binary:bin_to_list(BData)),
    PostData = "{\"method\":\"getmemorypool\",\"params\":[\"" ++ HexData ++ "\"]}",
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
    EncTx = btc_protocol:encode_tx(CoinbaseTx),
    HashedTx = ecoinpool_hash:dsha256_hash(EncTx),
    HashMerkleRoot = ecoinpool_util:byte_reverse(ecoinpool_hash:fold_tree_branches_dsha256_hash(HashedTx, FT)),
    #btc_header{hash_prev_block=HashPrevBlock, hash_merkle_root=HashMerkleRoot, timestamp=Timestamp, bits=Bits}.

make_coinbase_tx(#memorypool{timestamp=Timestamp, coinbase_value=CoinbaseValue}, Tag, PubkeyHash160, ScriptSigTrailer) ->
    TxIn = #btc_tx_in{
        prev_output_hash = <<0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0>>,
        prev_output_index = 16#ffffffff,
        signature_script = [Tag, Timestamp, 0 | ScriptSigTrailer]
    },
    TxOut = #btc_tx_out{
        value = CoinbaseValue,
        pk_script = [op_dup, op_hash160, PubkeyHash160, op_equalverify, op_checksig]
    },
    #btc_tx{tx_in=[TxIn], tx_out=[TxOut]}.

increment_coinbase_extra_nonce(Tx=#btc_tx{tx_in=[TxIn]}) ->
    #btc_tx_in{signature_script = [Tag, Timestamp, ExtraNonce | ScriptSigTrailer]} = TxIn,
    Tx#btc_tx{tx_in=[TxIn#btc_tx_in{signature_script = [Tag, Timestamp, ExtraNonce+1 | ScriptSigTrailer]}]}.

make_workunit(Header=#btc_header{bits=Bits}, BlockNum, AuxWork) ->
    BHeader = btc_protocol:encode_header(Header),
    WUId = workunit_id_from_btc_header(Header),
    Target = ecoinpool_util:bits_to_target(Bits),
    #workunit{id=WUId, ts=erlang:now(), target=Target, block_num=BlockNum, data=BHeader, aux_work=AuxWork}.

memorypools_equivalent(
            #memorypool{hash_prev_block=A, bits=B, first_tree_branches=C, coinbase_value=D},
            #memorypool{hash_prev_block=A, bits=B, first_tree_branches=C, coinbase_value=D}
        ) ->
    true;
memorypools_equivalent(_, _) ->
    false.

make_script_sig_trailer(undefined) ->
    [];
make_script_sig_trailer(#auxwork{aux_hash=AuxHash}) ->
    AuxHashLE = ecoinpool_util:byte_reverse(AuxHash),
    [<<250,190,109,109, AuxHashLE/binary, 1,0,0,0,0,0,0,0>>].
