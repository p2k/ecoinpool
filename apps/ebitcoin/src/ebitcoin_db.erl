
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
-include("ebitcoin_db_records.hrl").

-export([
    start_link/1,
    get_configuration/0,
    get_client_record/1,
    setup_client_dbs/1,
    store_block/3,
    store_header/3,
    store_headers/2,
    cut_branch/2,
    get_block_info/2,
    get_last_block_info/1,
    get_block_height/2,
    get_block_locator_hashes/2,
    set_view_update_interval/1,
    force_view_updates/1,
    update_site/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    srv_conn,
    conf_db,
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

get_configuration() ->
    gen_server:call(?MODULE, get_configuration).

get_client_record(ClientId) ->
    gen_server:call(?MODULE, {get_client_record, ClientId}).

setup_client_dbs(#client{name=ClientName, chain=Chain}) ->
    gen_server:call(?MODULE, {setup_client_dbs, ClientName, Chain}).

store_block(#client{name=ClientName}, BlockNum, Block) ->
    gen_server:cast(?MODULE, {store_block, ClientName, BlockNum, Block}).

store_header(#client{name=ClientName}, BlockNum, Header) ->
    gen_server:cast(?MODULE, {store_header, ClientName, BlockNum, Header}).

-spec store_headers(Client :: #client{}, Headers :: [{BlockNum :: integer(), BlockHash :: binary(), Header :: btc_header()}]) -> ok.
store_headers(#client{name=ClientName}, Headers) ->
    gen_server:cast(?MODULE, {store_headers, ClientName, Headers}).

cut_branch(#client{name=ClientName}, Height) ->
    gen_server:cast(?MODULE, {cut_branch, ClientName, Height}).

get_block_info(#client{name=ClientName}, BlockHashOrHeight) ->
    gen_server:call(?MODULE, {get_block_info, ClientName, BlockHashOrHeight}, infinity).

get_last_block_info(#client{name=ClientName}) ->
    gen_server:call(?MODULE, {get_last_block_info, ClientName}, infinity).

get_block_height(#client{name=ClientName}, Hash) when byte_size(Hash) =:= 32 ->
    gen_server:call(?MODULE, {get_block_height, ClientName, ecoinpool_util:bin_to_hexbin(Hash)}, infinity);
get_block_height(#client{name=ClientName}, HexHash) when byte_size(HexHash) =:= 64 ->
    gen_server:call(?MODULE, {get_block_height, ClientName, HexHash}, infinity).

get_block_locator_hashes(#client{name=ClientName}, StartBlockNum) ->
    gen_server:call(?MODULE, {get_block_locator_hashes, ClientName, StartBlockNum}, infinity).

set_view_update_interval(Seconds) ->
    gen_server:cast(?MODULE, {set_view_update_interval, Seconds}).

force_view_updates(#client{name=ClientName}) ->
    gen_server:cast(?MODULE, {force_view_updates, ClientName}).

update_site() ->
    gen_server:cast(?MODULE, update_site).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([{DBHost, DBPort, DBPrefix, DBOptions}]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Connect to server
    S = couchbeam:server_connection(DBHost, DBPort, DBPrefix, DBOptions),
    % Open config database
    ConfDb = case couchbeam:open_or_create_db(S, "ebitcoin") of
        {ok, DB} ->
            lists:foreach(fun check_design_doc/1, [
                {DB, "doctypes", "main_db_doctypes.json"},
                {DB, "clients", "main_db_clients.json"},
                {DB, "auth", "common_auth.json"},
                {DB, "site", "main_db_site.json"}
            ]),
            DB;
        {error, Error} ->
            log4erl:fatal(ebitcoin, "config_db - couchbeam:open_or_create_db/3 returned an error:~n~p", [Error]), throw({error, Error})
    end,
    % Start config monitor (asynchronously)
    gen_server:cast(?MODULE, start_cfg_monitor),
    % Return initial state
    {ok, #state{srv_conn=S, conf_db=ConfDb}}.

handle_call(get_configuration, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, "configuration") of
        {ok, {DocProps}} ->
            % Unpack and parse data
            DocType = proplists:get_value(<<"type">>, DocProps),
            ActiveClientsIds = proplists:get_value(<<"active_clients">>, DocProps, []),
            ViewUpdateInterval = proplists:get_value(<<"view_update_interval">>, DocProps, 300),
            ActiveClientsIdsCheck = if is_list(ActiveClientsIds) -> lists:all(fun is_binary/1, ActiveClientsIds); true -> false end,
            
            if % Validate data
                DocType =:= <<"configuration">>,
                is_integer(ViewUpdateInterval),
                ActiveClientsIdsCheck ->
                    % Create record
                    Configuration = #configuration{
                        active_clients=ActiveClientsIds,
                        view_update_interval=if ViewUpdateInterval > 0 -> ViewUpdateInterval; true -> 0 end
                    },
                    {reply, {ok, Configuration}, State};
                true ->
                    {reply, {error, invalid}, State}
            end;
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_client_record, ClientId}, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, ClientId) of
        {ok, Doc} ->
            {reply, parse_client_document(ClientId, Doc), State};
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({setup_client_dbs, ClientName, Chain}, _From, State=#state{srv_conn=S}) ->
    SClientDB = binary:bin_to_list(ClientName),
    SClientTxDB = SClientDB ++ "-tx",
    Existed = couchbeam:db_exists(S, SClientDB),
    case {couchbeam:open_or_create_db(S, SClientDB), couchbeam:open_or_create_db(S, SClientTxDB)} of
        {{ok, ClientDB}, {ok, ClientTxDB}} ->
            lists:foreach(fun check_design_doc/1, [
                {ClientDB, "headers", "client_db_headers.json"},
                {ClientDB, "auth", "common_auth.json"},
                {ClientTxDB, "transactions", "client_tx_db_transactions.json"},
                {ClientTxDB, "auth", "common_auth.json"}
            ]),
            if
                not Existed ->
                    save_genesis_block(Chain, ClientDB, ClientTxDB),
                    log4erl:info(ebitcoin, "Client databases \"~s\" and \"~s\" created!", [SClientDB, SClientTxDB]);
                true ->
                    ok
            end,
            {reply, ok, State};
        _ ->
            log4erl:error(ebitcoin, "client_db - errors occurred while creating client databases!"),
            {reply, error, State}
    end;

handle_call({get_block_info, ClientName, BlockHash}, _From, State=#state{srv_conn=S}) when is_binary(BlockHash) ->
    {ok, ClientDB} = couchbeam:open_db(S, binary:bin_to_list(ClientName)),
    case couchbeam:open_doc(ClientDB, ecoinpool_util:bin_to_hexbin(BlockHash)) of
        {ok, {DocProps}} ->
            BlockHeight = proplists:get_value(<<"block_num">>, DocProps),
            HasTransactions = proplists:get_value(<<"n_tx">>, DocProps) =/= 0,
            {reply, {BlockHeight, BlockHash, HasTransactions}, State};
        _ ->
            {reply, error, State}
    end;

handle_call({get_block_info, ClientName, BlockHeight}, _From, State=#state{srv_conn=S}) when is_integer(BlockHeight) ->
    {ok, ClientDB} = couchbeam:open_db(S, binary:bin_to_list(ClientName)),
    case couchbeam_view:fetch(ClientDB, {"headers", "by_block_num"}, [{key, BlockHeight}, {limit, 1}]) of
        {ok, []} ->
            {reply, error, State};
        {ok, [{RowProps}]} ->
            BlockHash = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"id">>, RowProps)),
            handle_call({get_block_info, ClientName, BlockHash}, _From, State)
    end;

handle_call({get_last_block_info, ClientName}, _From, State=#state{srv_conn=S}) ->
    {ok, ClientDB} = couchbeam:open_db(S, binary:bin_to_list(ClientName)),
    case couchbeam_view:fetch(ClientDB, {"headers", "by_block_num"}, [{limit, 1}, descending]) of
        {ok, []} ->
            {reply, error, State};
        {ok, [{RowProps}]} ->
            BlockNum = proplists:get_value(<<"key">>, RowProps),
            BlockHash = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"id">>, RowProps)),
            {reply, {BlockNum, BlockHash}, State}
    end;

handle_call({get_block_height, ClientName, HexHash}, _From, State=#state{srv_conn=S}) ->
    {ok, ClientDB} = couchbeam:open_db(S, binary:bin_to_list(ClientName)),
    case couchbeam:open_doc(ClientDB, HexHash) of
        {error, Reason} ->
            {reply, {error, Reason}, State};
        {ok, {DocProps}} ->
            {reply, {ok, proplists:get_value(<<"block_num">>, DocProps)}, State}
    end;

handle_call({get_block_locator_hashes, ClientName, StartBlockNum}, _From, State=#state{srv_conn=S}) ->
    {ok, ClientDB} = couchbeam:open_db(S, binary:bin_to_list(ClientName)),
    BLN = block_locator_numbers(StartBlockNum),
    {ok, Rows} = couchbeam_view:fetch(ClientDB, {"headers", "by_block_num"}, [{keys, BLN}]),
    {Hashes, _} = lists:foldr(
        fun ({RowProps}, {Acc, LastBN}) ->
            ThisBN = proplists:get_value(<<"key">>, RowProps),
            if
                ThisBN =/= LastBN ->
                    Hash = ecoinpool_util:hexbin_to_bin(proplists:get_value(<<"id">>, RowProps)),
                    {[Hash|Acc], ThisBN};
                true ->
                    {Acc, LastBN}
            end
        end,
        {[], undefined},
        Rows
    ),
    {reply, Hashes, State};

handle_call(_Message, _From, State=#state{}) ->
    {reply, error, State}.

handle_cast(start_cfg_monitor, State=#state{conf_db=ConfDb}) ->
    case ebitcoin_db_sup:start_cfg_monitor(ConfDb) of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,
    {noreply, State};

handle_cast({store_block, ClientName, BlockNum, Block}, State=#state{srv_conn=S}) ->
    ClientDBName = binary:bin_to_list(ClientName),
    {ok, ClientDB} = couchbeam:open_db(S, ClientDBName),
    
    #btc_block{header=Header, txns=Txns} = Block,
    BlockHash = ecoinpool_util:bin_to_hexbin(btc_protocol:get_hash(Header)),
    
    StoreTransactions = case couchbeam:open_doc(ClientDB, BlockHash) of
        {error, _} -> % Create new, full header
            save_doc(ClientDB, make_block_header_document(BlockNum, BlockHash, Header, length(Txns))) =:= ok;
        {ok, Doc} -> % Update existing partial header
            case couchbeam_doc:get_value(<<"n_tx">>, Doc) of
                0 ->
                    save_doc(ClientDB, couchbeam_doc:set_value(<<"n_tx">>, length(Txns), Doc)) =:= ok;
                _ ->
                    log4erl:info(ebitcoin, "store_block: Skipping an already existing block."),
                    false
            end
    end,
    if
        StoreTransactions ->
            {ok, ClientTxDB} = couchbeam:open_db(S, ClientDBName ++ "-tx"),
            lists:foldl(
                fun (Tx, Index) ->
                    save_doc(ClientTxDB, make_tx_document(BlockHash, Index, Tx)),
                    Index + 1
                end,
                0,
                Txns
            ),
            {noreply, store_view_update(ClientDBName, erlang:now(), State)};
        true ->
            {noreply, State}
    end;

handle_cast({store_header, ClientName, BlockNum, Header}, State=#state{srv_conn=S}) ->
    ClientDBName = binary:bin_to_list(ClientName),
    {ok, ClientDB} = couchbeam:open_db(S, ClientDBName),
    BlockHash = ecoinpool_util:bin_to_hexbin(btc_protocol:get_hash(Header)),
    % Store partial header
    case save_doc(ClientDB, make_block_header_document(BlockNum, BlockHash, Header, 0)) of
        ok ->
            {noreply, store_view_update(ClientDBName, erlang:now(), State)};
        _ ->
            {noreply, State}
    end;

handle_cast({store_headers, ClientName, Headers}, State=#state{srv_conn=S}) ->
    ClientDBName = binary:bin_to_list(ClientName),
    {ok, ClientDB} = couchbeam:open_db(S, ClientDBName),
    Docs = make_block_header_documents(Headers),
    couchbeam:save_docs(ClientDB, Docs),
    {noreply, store_view_update(ClientDBName, erlang:now(), State)};

handle_cast({cut_branch, ClientName, Height}, State=#state{srv_conn=S}) ->
    ClientDBName = binary:bin_to_list(ClientName),
    {ok, ClientDB} = couchbeam:open_db(S, ClientDBName),
    case couchbeam_view:fetch(ClientDB, {"headers", "by_block_num"}, [{start_key, Height}, include_docs]) of
        {ok, []} ->
            ok;
        {ok, Rows} ->
            {Hashes, Docs} = lists:unzip(lists:map(
                fun ({RowProps}) ->
                    Doc = proplists:get_value(<<"doc">>, RowProps),
                    Hash = case couchbeam_doc:get_value(<<"n_tx">>, Doc) of
                        0 -> undefined;
                        _ -> proplists:get_value(<<"id">>, RowProps)
                    end,
                    {Hash, Doc}
                end,
                Rows
            )),
            couchbeam:delete_docs(ClientDB, Docs),
            {ok, ClientTxDB} = couchbeam:open_db(S, ClientDBName ++ "-tx"),
            lists:foreach(
                fun
                    (undefined) -> ok;
                    (Hash) ->
                        {ok, Rows2} = couchbeam_view:fetch(ClientTxDB, {"transactions", "by_block_hash"}, [{start_key, [Hash, 0]}, {end_key, [Hash, {[]}]}, include_docs]),
                        Docs2 = lists:map(fun ({RowProps}) -> proplists:get_value(<<"doc">>, RowProps) end, Rows2),
                        couchbeam:delete_docs(ClientDB, Docs2)
                end,
                Hashes
            )
    end,
    {noreply, State};

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

handle_cast({force_view_updates, ClientName}, State=#state{srv_conn=S, view_update_running=ViewUpdateRunning}) ->
    DBName = binary:bin_to_list(ClientName),
    case ViewUpdateRunning of
        false ->
            PID = self(),
            spawn(fun () -> do_update_views([DBName], S, PID) end),
            {noreply, State#state{view_update_running=erlang:now()}};
        _ ->
            {noreply, State} % Cannot force update while already running
    end;

handle_cast(update_site, State=#state{conf_db=ConfDb}) ->
    {ok, SDoc} = file:read_file(filename:join(code:priv_dir(ebitcoin), "main_db_site.json")),
    Doc = ejson:decode(SDoc),
    case couchbeam:lookup_doc_rev(ConfDb, "_design/site") of
        {error, not_found} ->
            {ok, _} = couchbeam:save_doc(ConfDb, Doc),
            {noreply, State};
        Rev ->
            {ok, _} = couchbeam:save_doc(ConfDb, couchbeam_doc:set_value(<<"_rev">>, Rev, Doc)),
            {noreply, State}
    end;

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(update_views, State=#state{view_update_dbs=undefined}) ->
    {noreply, State};

handle_info(update_views, State=#state{srv_conn=S, view_update_interval=ViewUpdateInterval, view_update_running=ViewUpdateRunning, view_update_dbs=ViewUpdateDBS}) ->
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
                    spawn(fun () -> do_update_views(DBS, S, PID) end),
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

check_design_doc({DB, Name, Filename}) ->
    case couchbeam:doc_exists(DB, "_design/" ++ Name) of
        true ->
            ok;
        false ->
            {ok, SDoc} = file:read_file(filename:join(code:priv_dir(ebitcoin), Filename)),
            {ok, _} = couchbeam:save_doc(DB, ejson:decode(SDoc)),
            ok
    end.

do_update_views(DBS, S, PID) ->
    try
        lists:foreach(
            fun (DBName) ->
                {ok, DB} = couchbeam:open_db(S, DBName),
                couchbeam_view:fetch(DB, {"headers", "by_block_num"}, [{limit, 1}]),
                {ok, TxDB} = couchbeam:open_db(S, DBName ++ "-tx"),
                couchbeam_view:fetch(TxDB, {"transactions", "by_block_hash"}, [{limit, 1}])
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

parse_client_document(ClientId, {DocProps}) ->
    DocType = proplists:get_value(<<"type">>, DocProps),
    Name = proplists:get_value(<<"name">>, DocProps),
    {Chain, DefaultPort} = ebitcoin_chain_data:type_and_port(proplists:get_value(<<"chain">>, DocProps)),
    Host = proplists:get_value(<<"host">>, DocProps, <<"localhost">>),
    Port = proplists:get_value(<<"port">>, DocProps, DefaultPort),
    
    if
        DocType =:= <<"client">>,
        is_binary(Name),
        Name =/= <<>>,
        Chain =/= undefined,
        is_binary(Host),
        Host =/= <<>>,
        is_integer(Port) ->
            
            % Create record
            Client = #client{
                id=ClientId,
                name=Name,
                chain=Chain,
                host=Host,
                port=Port
            },
            {ok, Client};
        
        true ->
            {error, invalid}
    end.

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
    {DecodedTx, _} = btc_protocol:decode_tx(Tx),
    make_btc_tx_part(DecodedTx);
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

make_block_header_document(BlockNum, BlockHash, Header=#btc_header{}, NTx) ->
    {HeaderPart} = make_btc_header_part(Header),
    DocProps = [
        {<<"_id">>, BlockHash},
        {<<"block_num">>, BlockNum},
        {<<"n_tx">>, NTx}
    ] ++ HeaderPart,
    
    case Header#btc_header.auxpow of
        undefined ->
            {DocProps};
        AuxPOW ->
            {DocProps ++ [{<<"aux_pow">>, make_btc_aux_pow_part(AuxPOW)}]}
    end.

make_block_header_documents(Headers) ->
    [make_block_header_document(BlockNum, ecoinpool_util:bin_to_hexbin(BlockHash), Header, 0) || {BlockNum, BlockHash, Header} <- Headers].

make_tx_document(BlockHash, Index, Tx=#btc_tx{}) ->
    {TxPart} = make_btc_tx_part(Tx),
    {[
        {<<"_id">>, ecoinpool_util:bin_to_hexbin(btc_protocol:get_hash(Tx))},
        {<<"block_hash">>, BlockHash},
        {<<"index">>, Index}
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
store_view_update(DBName, TS, State=#state{view_update_dbs=ViewUpdateDBS}) ->
    State#state{view_update_dbs=dict:store(DBName, TS, ViewUpdateDBS)}.

save_genesis_block(Chain, ClientDB, ClientTxDB) ->
    {BlockHash, Header, Tx} = ebitcoin_chain_data:genesis_block(Chain),
    ok = save_doc(ClientDB, make_block_header_document(0, BlockHash, Header, 1)),
    ok = save_doc(ClientTxDB, make_tx_document(BlockHash, 0, Tx)).

block_locator_numbers(StartBlockNum) ->
    if
        StartBlockNum =< 12 ->
            lists:seq(StartBlockNum, 0, -1);
        true ->
            lists:reverse(block_locator_numbers(StartBlockNum-11, 2, lists:seq(StartBlockNum-10, StartBlockNum, 1)))
    end.

block_locator_numbers(0, _, Acc) ->
    [0|Acc];
block_locator_numbers(BN, S, Acc) ->
    block_locator_numbers(max(0, BN-S), S*2, [BN|Acc]).
