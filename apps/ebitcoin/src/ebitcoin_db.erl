
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ebitcoin.
%%
%% ebitcoin is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ebitcoin is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ebitcoin.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ebitcoin_db).
-behaviour(gen_server).

-include("btc_protocol_records.hrl").

-export([
    start_link/1,
    setup_chain_db/1,
    store_block/3,
    store_header/3,
    store_header/4,
    set_view_update_interval/1
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    srv_conn,
    view_update_interval = 0,
    view_update_timer,
    view_update_dbs,
    view_update_running = false
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link({DBHost, DBPort, DBPrefix, DBOptions}) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [{DBHost, DBPort, DBPrefix, DBOptions}], []).

setup_chain_db(Chain) ->
    gen_server:call(?MODULE, {setup_chain_db, Chain}).

store_block(Chain, BlockNum, Block) ->
    gen_server:cast(?MODULE, {store_block, Chain, BlockNum, Block}).

store_header(Chain, BlockNum, Header) ->
    gen_server:cast(?MODULE, {store_header, Chain, BlockNum, Header, undefined}).

store_header(Chain, BlockNum, Header, AuxPOW) ->
    gen_server:cast(?MODULE, {store_header, Chain, BlockNum, Header, AuxPOW}).

set_view_update_interval(Seconds) ->
    gen_server:cast(?MODULE, {set_view_update_interval, Seconds}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([{DBHost, DBPort, DBPrefix, DBOptions}]) ->
    % Connect to database
    S = couchbeam:server_connection(DBHost, DBPort, DBPrefix, DBOptions),
    % Return initial state
    {ok, #state{srv_conn=S}}.

handle_call({setup_chain_db, Chain}, _From, State=#state{srv_conn=S}) ->
    SChain = atom_to_list(Chain),
    case couchbeam:db_exists(S, SChain) of
        true ->
            {reply, ok, State};
        _ ->
            case couchbeam:create_db(S, SChain) of
                {ok, DB} ->
                    {ok, _} = couchbeam:save_doc(DB, {[
                        {<<"_id">>, <<"_design/headers">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"views">>, {[
                            {<<"by_block_num">>, {[
                                {<<"map">>, <<"function(doc) {if (doc.type === \"header\") emit(doc.block_num, null);}">>}
                            ]}},
                            {<<"next_header">>, {[
                                {<<"map">>, <<"function(doc) {if (doc.type === \"header\") emit(doc.prev_block, null);}">>}
                            ]}}
                        ]}}
                    ]}),
                    {ok, _} = couchbeam:save_doc(DB, {[
                        {<<"_id">>, <<"_design/transactions">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"views">>, {[
                            {<<"by_block_num">>, {[
                                {<<"map">>, <<"function(doc) {if (doc.type === \"tx\") emit([doc.block_hash, doc.index], null);}">>}
                            ]}}
                        ]}}
                    ]}),
                    log4erl:info(ebitcoin, "Chain database \"~p\" created!", [Chain]),
                    {reply, ok, State};
                {error, Error} ->
                    log4erl:error(ebitcoin, "chain_db - couchbeam:open_or_create_db/3 returned an error:~n~p", [Error]),
                    {reply, error, State}
            end
    end;

handle_call(_Message, _From, State=#state{}) ->
    {reply, error, State}.

handle_cast({store_block, Chain, BlockNum, Block}, State=#state{srv_conn=S}) ->
    SChain = atom_to_list(Chain),
    {ok, ChainDB} = couchbeam:open_db(S, SChain),
    
    #btc_block{header=Header, auxpow=AuxPOW, txns=Txns} = Block,
    BlockHash = get_hash(Header),
    
    HeaderDocSaved = case couchbeam:doc_exists(ChainDB, BlockHash) of
        false ->
            case save_doc(ChainDB, make_block_header_document(BlockNum, BlockHash, Header, AuxPOW)) of
                ok ->
                    true;
                _ ->
                    false
            end;
        true ->
            true
    end,
    if
        HeaderDocSaved ->
            lists:foldl(
                fun (Tx, Index) ->
                    save_doc(ChainDB, make_tx_document(BlockHash, Index, Tx)),
                    Index + 1
                end,
                0,
                Txns
            ),
            {noreply, store_view_update(ChainDB, erlang:now(), State)};
        true ->
            {noreply, State}
    end;

handle_cast({store_header, Chain, BlockNum, Header, AuxPOW}, State=#state{srv_conn=S}) ->
    SChain = atom_to_list(Chain),
    {ok, ChainDB} = couchbeam:open_db(S, SChain),
    BlockHash = get_hash(Header),
    case save_doc(ChainDB, make_block_header_document(BlockNum, BlockHash, Header, AuxPOW)) of
        ok ->
            {noreply, store_view_update(ChainDB, erlang:now(), State)};
        _ ->
            {noreply, State}
    end;

handle_cast({set_view_update_interval, Seconds}, State=#state{view_update_interval=OldViewUpdateInterval, view_update_timer=OldViewUpdateTimer, view_update_dbs=OldViewUpdateDBS}) ->
    if
        Seconds =:= OldViewUpdateInterval ->
            {noreply, State}; % No change
        true ->
            timer:cancel(OldViewUpdateTimer),
            case Seconds of
                0 ->
                    log4erl:info(ebitcoin, "View updates disabled."),
                    {noreply, State#state{view_update_interval=0, view_update_timer=undefined, view_update_dbs=undefined}};
                _ ->
                    log4erl:info(ebitcoin, "Set view update timer to ~bs.", [Seconds]),
                    {ok, Timer} = timer:send_interval(Seconds * 1000, update_views),
                    ViewUpdateDBS = case OldViewUpdateDBS of
                        undefined -> dict:new();
                        _ -> OldViewUpdateDBS
                    end,
                    {noreply, State#state{view_update_interval=Seconds, view_update_timer=Timer, view_update_dbs=ViewUpdateDBS}}
            end
    end;

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(update_views, State=#state{view_update_dbs=undefined}) ->
    {noreply, State};

handle_info(update_views, State=#state{view_update_interval=ViewUpdateInterval, view_update_running=ViewUpdateRunning, view_update_dbs=ViewUpdateDBS}) ->
    case ViewUpdateRunning of
        false ->
            Now = erlang:now(),
            USecLimit = ViewUpdateInterval * 1000000,
            NewViewUpdateDBS = dict:filter(
                fun (_, TS) -> timer:now_diff(Now, TS) =< USecLimit end,
                ViewUpdateDBS
            ),
            case dict:size(NewViewUpdateDBS) of
                0 ->
                    {noreply, State#state{view_update_dbs=NewViewUpdateDBS}};
                _ ->
                    DBS = dict:fetch_keys(NewViewUpdateDBS),
                    PID = self(),
                    spawn(fun () -> do_update_views(DBS, PID) end),
                    {noreply, State#state{view_update_running=erlang:now(), view_update_dbs=NewViewUpdateDBS}}
            end;
        _ ->
            {noreply, State} % Ignore message if already running
    end;

handle_info(view_update_complete, State=#state{view_update_running=ViewUpdateRunning}) ->
    MS = timer:now_diff(erlang:now(), ViewUpdateRunning),
    log4erl:info(ebitcoin, "View update finished after ~.1fs.", [MS / 1000000]),
    {noreply, State#state{view_update_running=false}};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{view_update_timer=ViewUpdateTimer}) ->
    case ViewUpdateTimer of
        undefined -> ok;
        _ -> timer:cancel(ViewUpdateTimer)
    end,
    ok.

code_change(_OldVersion, State=#state{}, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

do_update_views(DBS, PID) ->
    try
        lists:foreach(
            fun (DB) ->
                couchbeam_view:fetch(DB, {"headers", "by_block_num"}),
                couchbeam_view:fetch(DB, {"transactions", "by_block_hash"})
            end,
            DBS
        )
    catch
        exit:Reason ->
            log4erl:error(ebitcoin, "Exception in do_update_views:~n~p", [Reason]);
        error:Reason ->
            log4erl:error(ebitcoin, "Exception in do_update_views:~n~p", [Reason])
    end,
    PID ! view_update_complete.

get_hash(Bin) when is_binary(Bin) ->
    ecoinpool_util:bin_to_hexbin(ecoinpool_hash:dsha256_hash(Bin));
get_hash(Header=#btc_header{}) ->
    get_hash(btc_protocol:encode_header(Header));
get_hash(Tx=#btc_tx{}) ->
    get_hash(btc_protocol:encode_tx(Tx)).

make_btc_header_part(Header) ->
    #btc_header{
        version = Version,
        hash_prev_block = HashPrevBlock,
        hash_merkle_root = HashMerkleRoot,
        timestamp = Timestamp,
        bits = Bits,
        nonce = Nonce
    } = Header,
    
    {[
        {<<"ver">>, Version},
        {<<"prev_block">>, ecoinpool_util:bin_to_hexbin(HashPrevBlock)},
        {<<"mrkl_root">>, ecoinpool_util:bin_to_hexbin(HashMerkleRoot)},
        {<<"time">>, Timestamp},
        {<<"bits">>, Bits},
        {<<"nonce">>, Nonce}
    ]}.

make_btc_tx_in_part(TxIn) ->
    #btc_tx_in{
        prev_output_hash=PrevOutputHash,
        prev_output_index=PrevOutputIndex,
        signature_script=SignatureScript,
        sequence=Sequence
    } = TxIn,
    
    BSignatureScript = if
        is_list(SignatureScript) ->
            btc_protocol:encode_script(SignatureScript);
        true ->
            SignatureScript
    end,
    
    {[
        {<<"prev_out_hash">>, ecoinpool_util:bin_to_hexbin(PrevOutputHash)},
        {<<"prev_out_index">>, case PrevOutputIndex of 4294967295 -> -1; _ -> PrevOutputIndex end},
        {<<"script">>, base64:encode(BSignatureScript)},
        {<<"seq">>, case Sequence of 4294967295 -> -1; _ -> Sequence end}
    ]}.

make_btc_tx_out_part(#btc_tx_out{value=Value, pk_script=PKScript}) ->
    BPKScript = if
        is_list(PKScript) ->
            btc_protocol:encode_script(PKScript);
        true ->
            PKScript
    end,
    
    SValue = lists:flatten(io_lib:format("~.8f", [Value / 100000000])),
    
    {[
        {<<"value">>, binary:list_to_bin(SValue)},
        {<<"script">>, base64:encode(BPKScript)}
    ]}.

make_btc_tx_part(Tx) when is_binary(Tx) ->
    make_btc_tx_part(btc_protocol:decode_tx(Tx));
make_btc_tx_part(#btc_tx{version=Version, tx_in=TxIn, tx_out=TxOut, lock_time=LockTime}) ->
    {[
        {<<"ver">>, Version},
        {<<"in">>, lists:map(fun make_btc_tx_in_part/1, TxIn)},
        {<<"out">>, lists:map(fun make_btc_tx_out_part/1, TxOut)},
        {<<"lock_time">>, LockTime}
    ]}.

make_btc_aux_pow_part(AuxPOW) ->
    #btc_auxpow{
        coinbase_tx = CoinbaseTx,
        block_hash = BlockHash,
        tx_tree_branches = TxTreeBranches,
        tx_index = TxIndex,
        aux_tree_branches = AuxTreeBranches,
        aux_index = AuxIndex,
        parent_header = ParentHeader
    } = AuxPOW,
    
    {[
        {<<"coinbase_tx">>, make_btc_tx_part(CoinbaseTx)},
        {<<"block_hash">>, ecoinpool_util:bin_to_hexbin(BlockHash)},
        {<<"tx_tree_branches">>, lists:map(fun ecoinpool_util:bin_to_hexbin/1, TxTreeBranches)},
        {<<"tx_index">>, TxIndex},
        {<<"aux_tree_branches">>, lists:map(fun ecoinpool_util:bin_to_hexbin/1, AuxTreeBranches)},
        {<<"aux_index">>, AuxIndex},
        {<<"parent_header">>, make_btc_header_part(ParentHeader)}
    ]}.

make_block_header_document(BlockNum, BlockHash, Header=#btc_header{}, AuxPOW) ->
    {HeaderPart} = make_btc_header_part(Header),
    DocProps = [
        {<<"_id">>, BlockHash},
        {<<"type">>, <<"header">>},
        {<<"block_num">>, BlockNum}
    ] ++ HeaderPart,
    
    case AuxPOW of
        undefined ->
            {DocProps};
        _ ->
            {DocProps ++ [{<<"aux_pow">>, make_btc_aux_pow_part(AuxPOW)}]}
    end.

make_tx_document(BlockHash, Index, Tx=#btc_tx{}) ->
    {TxPart} = make_btc_tx_part(Tx),
    {[
        {<<"_id">>, get_hash(Tx)},
        {<<"type">>, <<"tx">>},
        {<<"index">>, Index},
        {<<"block_hash">>, BlockHash}
    ] ++ TxPart}.

save_doc(DB, Doc) ->
    try
        couchbeam:save_doc(DB, Doc),
        ok
    catch error:Reason ->
        log4erl:warn(ebitcoin, "save_doc: ignored error:~n~p", [Reason]),
        error
    end.

store_view_update(_, _, State=#state{view_update_dbs=undefined}) ->
    State;
store_view_update(DB, TS, State=#state{view_update_dbs=ViewUpdateDBS}) ->
    State#state{view_update_dbs=dict:store(DB, TS, ViewUpdateDBS)}.
