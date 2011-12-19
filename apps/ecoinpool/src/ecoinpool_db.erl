
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

-module(ecoinpool_db).
-behaviour(gen_server).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([
    start_link/1,
    get_configuration/0,
    get_subpool_record/1,
    get_worker_record/1,
    get_workers_for_subpools/1,
    set_subpool_round/2,
    set_auxpool_round/2,
    setup_shares_db/1,
    store_share/6,
    store_invalid_share/4,
    store_invalid_share/5,
    store_invalid_share/6,
    set_view_update_interval/1
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

-spec start_link({DBHost :: string(), DBPort :: integer(), DBPrefix :: string(), DBOptions :: [term()]}) -> {ok, pid()} | ignore | {error, {already_started, pid()} | term()}.
start_link({DBHost, DBPort, DBPrefix, DBOptions}) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [{DBHost, DBPort, DBPrefix, DBOptions}], []).

-spec get_configuration() -> {ok, configuration()} | {error, invalid | missing}.
get_configuration() ->
    gen_server:call(?MODULE, get_configuration).

-spec get_subpool_record(SubpoolId :: binary()) -> {ok, subpool()} | {error, invalid | missing}.
get_subpool_record(SubpoolId) ->
    gen_server:call(?MODULE, {get_subpool_record, SubpoolId}).

-spec get_worker_record(WorkerId :: binary()) -> {ok, worker()} | {error, invalid | missing}.
get_worker_record(WorkerId) ->
    gen_server:call(?MODULE, {get_worker_record, WorkerId}).

-spec get_workers_for_subpools(SubpoolIds :: [binary()]) -> [worker()].
get_workers_for_subpools(SubpoolIds) ->
    gen_server:call(?MODULE, {get_workers_for_subpools, SubpoolIds}).

-spec set_subpool_round(Subpool :: subpool(), Round :: integer()) -> ok.
set_subpool_round(#subpool{id=SubpoolId}, Round) ->
    gen_server:cast(?MODULE, {set_subpool_round, SubpoolId, Round}).

-spec set_auxpool_round(Subpool :: subpool(), Round :: integer()) -> ok.
set_auxpool_round(#subpool{id=SubpoolId}, Round) ->
    gen_server:cast(?MODULE, {set_auxpool_round, SubpoolId, Round}).

-spec setup_shares_db(SubpoolOrAuxpool :: subpool() | auxpool()) -> ok | error.
setup_shares_db(#subpool{name=SubpoolName}) ->
    gen_server:call(?MODULE, {setup_shares_db, SubpoolName});
setup_shares_db(#auxpool{name=AuxpoolName}) ->
    gen_server:call(?MODULE, {setup_shares_db, AuxpoolName}).

-spec store_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit(), Hash :: binary(), Candidates :: [candidate()]) -> ok.
store_share(Subpool, Peer, Worker, Workunit, Hash, Candidates) ->
    gen_server:cast(?MODULE, {store_share, Subpool, Peer, Worker, Workunit, Hash, Candidates}).

-spec store_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Reason :: reject_reason()) -> ok.
store_invalid_share(Subpool, Peer, Worker, Reason) ->
    store_invalid_share(Subpool, Peer, Worker, undefined, undefined, Reason).

-spec store_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Hash :: binary(), Reason :: reject_reason()) -> ok.
store_invalid_share(Subpool, Peer, Worker, Hash, Reason) ->
    store_invalid_share(Subpool, Peer, Worker, undefined, Hash, Reason).

-spec store_invalid_share(Subpool :: subpool(), Peer :: peer(), Worker :: worker(), Workunit :: workunit() | undefined, Hash :: binary() | undefined, Reason :: reject_reason()) -> ok.
store_invalid_share(Subpool, Peer, Worker, Workunit, Hash, Reason) ->
    gen_server:cast(?MODULE, {store_invalid_share, Subpool, Peer, Worker, Workunit, Hash, Reason}).

-spec set_view_update_interval(Seconds :: integer()) -> ok.
set_view_update_interval(Seconds) ->
    gen_server:cast(?MODULE, {set_view_update_interval, Seconds}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([{DBHost, DBPort, DBPrefix, DBOptions}]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Connect to server
    S = couchbeam:server_connection(DBHost, DBPort, DBPrefix, DBOptions),
    % Open config database
    ConfDb = case couchbeam:db_exists(S, "ecoinpool") of
        true ->
            {ok, TheConfDb} = couchbeam:open_db(S, "ecoinpool"),
            TheConfDb;
        _ ->
            case couchbeam:create_db(S, "ecoinpool") of
                {ok, NewConfDb} -> % Create basic views and auth lock-out
                    {ok, _} = couchbeam:save_doc(NewConfDb, {[
                        {<<"_id">>, <<"_design/doctypes">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"views">>, {[
                            {<<"doctypes">>, {[{<<"map">>, <<"function (doc) {if (doc.type !== undefined) emit(doc.type, doc._id);}">>}]}}
                        ]}},
                        {<<"filters">>, {[
                            {<<"pool_only">>, <<"function (doc, req) {return doc._deleted || doc.type == \"configuration\" || doc.type == \"sub-pool\";}">>},
                            {<<"workers_only">>, <<"function (doc, req) {return doc._deleted || doc.type == \"worker\";}">>}
                        ]}}
                    ]}),
                    {ok, _} = couchbeam:save_doc(NewConfDb, {[
                        {<<"_id">>, <<"_design/workers">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"views">>, {[
                            {<<"by_sub_pool">>, {[{<<"map">>, <<"function(doc) {if (doc.type === \"worker\") emit(doc.sub_pool_id, doc.name);}">>}]}},
                            {<<"by_name">>, {[{<<"map">>, <<"function(doc) {if (doc.type === \"worker\") emit(doc.name, doc.sub_pool_id);}">>}]}},
                            {<<"by_sub_pool_and_name">>, {[{<<"map">>, <<"function(doc) {if (doc.type === \"worker\") emit([doc.sub_pool_id, doc.name], doc.user_id);}">>}]}},
                            {<<"by_sub_pool_and_user_id">>, {[{<<"map">>, <<"function(doc) {if (doc.type === \"worker\") emit([doc.sub_pool_id, doc.user_id], doc.name);}">>}]}}
                        ]}}
                    ]}),
                    {ok, _} = couchbeam:save_doc(NewConfDb, {[
                        {<<"_id">>, <<"_design/auth">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"validate_doc_update">>, <<"function(newDoc, oldDoc, userCtx) {if (userCtx.roles.indexOf('_admin') !== -1) return; else throw({forbidden: 'Only admins may edit the database'});}">>}
                    ]}),
                    log4erl:info(db, "Config database created!"),
                    NewConfDb;
                {error, Error} ->
                    log4erl:fatal(db, "config_db - couchbeam:open_or_create_db/3 returned an error:~n~p", [Error]), throw({error, Error})
            end
    end,
    % Start config & worker monitor (asynchronously)
    gen_server:cast(?MODULE, start_monitors),
    % Return initial state
    {ok, #state{srv_conn=S, conf_db=ConfDb}}.

handle_call(get_configuration, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, "configuration") of
        {ok, {DocProps}} ->
            % Unpack and parse data
            DocType = proplists:get_value(<<"type">>, DocProps),
            ActiveSubpoolIds = proplists:get_value(<<"active_subpools">>, DocProps, []),
            ViewUpdateInterval = proplists:get_value(<<"view_update_interval">>, DocProps, 300),
            ActiveSubpoolIdsCheck = if is_list(ActiveSubpoolIds) -> lists:all(fun is_binary/1, ActiveSubpoolIds); true -> false end,
            
            if % Validate data
                DocType =:= <<"configuration">>,
                is_integer(ViewUpdateInterval),
                ActiveSubpoolIdsCheck ->
                    % Create record
                    Configuration = #configuration{
                        active_subpools=ActiveSubpoolIds,
                        view_update_interval=if ViewUpdateInterval > 0 -> ViewUpdateInterval; true -> 0 end
                    },
                    {reply, {ok, Configuration}, State};
                true ->
                    {reply, {error, invalid}, State}
            end;
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_subpool_record, SubpoolId}, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, SubpoolId) of
        {ok, Doc} ->
            {reply, parse_subpool_document(SubpoolId, Doc), State};
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_worker_record, WorkerId}, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, WorkerId) of
        {ok, Doc} ->
            {reply, parse_worker_document(WorkerId, Doc), State};
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_workers_for_subpools, SubpoolIds}, _From, State=#state{conf_db=ConfDb}) ->
    {ok, Rows} = couchbeam_view:fetch(ConfDb, {"workers", "by_sub_pool"}, [include_docs, {keys, SubpoolIds}]),
    Workers = lists:foldl(
        fun ({RowProps}, AccWorkers) ->
            Id = proplists:get_value(<<"id">>, RowProps),
            Doc = proplists:get_value(<<"doc">>, RowProps),
            case parse_worker_document(Id, Doc) of
                {ok, Worker} ->
                    [Worker|AccWorkers];
                {error, invalid} ->
                    log4erl:warn(db, "get_workers_for_subpools: Invalid document for worker ID \"~s\", ignoring.", [Id]),
                    AccWorkers
            end
        end,
        [],
        Rows
    ),
    {reply, Workers, State};

handle_call({setup_shares_db, SubpoolName}, _From, State=#state{srv_conn=S}) ->
    case couchbeam:db_exists(S, SubpoolName) of
        true ->
            {reply, ok, State};
        _ ->
            case couchbeam:create_db(S, SubpoolName) of
                {ok, DB} ->
                    {ok, _} = couchbeam:save_doc(DB, {[
                        {<<"_id">>, <<"_design/stats">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"views">>, {[
                            {<<"state">>, {[
                                {<<"map">>, <<"function(doc) {emit([doc.state, doc.user_id, doc.worker_id], 1);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {return sum(values);}">>}
                            ]}},
                            {<<"rejected">>, {[
                                {<<"map">>, <<"function(doc) {if (doc.state == \"invalid\") emit([doc.reject_reason, doc.user_id, doc.worker_id], 1);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {return sum(values);}">>}
                            ]}},
                            {<<"workers">>, {[
                                {<<"map">>, <<"function(doc) {var d = [0,0,0]; switch(doc.state) {case \"invalid\": d[0] = 1; break; case \"valid\": d[1] = 1; break; case \"candidate\": d[2] = 1; break;} emit(doc.worker_id, d);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {var s = [0,0,0]; for (var i in values) {var value = values[i]; s[0] += value[0]; s[1] += value[1]; s[2] += value[2];} return s;}">>}
                            ]}}
                        ]}}
                    ]}),
                    {ok, _} = couchbeam:save_doc(DB, {[
                        {<<"_id">>, <<"_design/timed_stats">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"views">>, {[
                            {<<"all_valids">>, {[
                                {<<"map">>, <<"function(doc) {if (doc.state == \"valid\" || doc.state == \"candidate\") emit(doc.timestamp, 1);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {return sum(values);}">>}
                            ]}},
                            {<<"valids_per_user">>, {[
                                {<<"map">>, <<"function(doc) {if (doc.state == \"valid\" || doc.state == \"candidate\") emit([doc.user_id].concat(doc.timestamp), 1);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {return sum(values);}">>}
                            ]}},
                            {<<"valids_per_worker">>, {[
                                {<<"map">>, <<"function(doc) {if (doc.state == \"valid\" || doc.state == \"candidate\") emit([doc.worker_id].concat(doc.timestamp), 1);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {return sum(values);}">>}
                            ]}},
                            {<<"worker_last_share">>, {[
                                {<<"map">>, <<"function(doc) {emit(doc.worker_id, [doc.timestamp, doc.state]);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {var cmp = function (a, b) {for (var i in a) {if (a[i] != b[i]) return (a[i] < b[i]);} return false;}; var best = null; for (var i in values) {if (best === null || cmp(best[0], values[i][0])) best = values[i];} return best;}">>}
                            ]}}
                        ]}}
                    ]}),
                    {ok, _} = couchbeam:save_doc(DB, {[
                        {<<"_id">>, <<"_design/auth">>},
                        {<<"language">>, <<"javascript">>},
                        {<<"validate_doc_update">>, <<"function(newDoc, oldDoc, userCtx) {if (userCtx.roles.indexOf('_admin') !== -1) return; else throw({forbidden: 'Only admins may edit the database'});}">>}
                    ]}),
                    log4erl:info(db, "Shares database \"~s\" created!", [SubpoolName]),
                    {reply, ok, State};
                {error, Error} ->
                    log4erl:error(db, "shares_db - couchbeam:open_or_create_db/3 returned an error:~n~p", [Error]),
                    {reply, error, State}
            end
    end;

handle_call(_Message, _From, State=#state{}) ->
    {reply, error, State}.

handle_cast(start_monitors, State=#state{conf_db=ConfDb}) ->
    case ecoinpool_db_sup:start_cfg_monitor(ConfDb) of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,
    case ecoinpool_db_sup:start_worker_monitor(ConfDb) of
        ok -> ok;
        {error, {already_started, _}} -> ok
    end,
    {noreply, State};

handle_cast({set_subpool_round, SubpoolId, Round}, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, SubpoolId) of
        {ok, Doc} ->
            UpdatedDoc = couchbeam_doc:set_value(<<"round">>, Round, Doc),
            couchbeam:save_doc(ConfDb, UpdatedDoc);
        _ -> % Ignore if missing
            ok
    end,
    {noreply, State};

handle_cast({set_auxpool_round, SubpoolId, Round}, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, SubpoolId) of
        {ok, Doc} ->
            AuxpoolObj = couchbeam_doc:get_value(<<"aux_pool">>, Doc, {[]}),
            UpdatedAuxpoolObj = couchbeam_doc:set_value(<<"round">>, Round, AuxpoolObj),
            UpdatedDoc = couchbeam_doc:set_value(<<"aux_pool">>, UpdatedAuxpoolObj, Doc),
            couchbeam:save_doc(ConfDb, UpdatedDoc);
        _ -> % Ignore if missing
            ok
    end,
    {noreply, State};

handle_cast({store_share,
            #subpool{name=SubpoolName, round=Round, aux_pool=Auxpool},
            Peer,
            #worker{id=WorkerId, user_id=UserId, name=WorkerName},
            #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock, data=BData, aux_work=AuxWork, aux_work_stale=AuxWorkStale},
            Hash,
            Candidates}, State=#state{srv_conn=S}) ->
    % This code will change if multi aux chains are supported
    Now = erlang:now(),
    {MainState, AuxState} = lists:foldl(
        fun
            (main, {_, AS}) -> {candidate, AS};
            (aux, {MS, _}) -> {MS, candidate};
            (_, Acc) -> Acc
        end,
        {valid, valid},
        Candidates
    ),
    
    NewState = case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} when AuxWork =/= undefined ->
            {ok, AuxDB} = couchbeam:open_db(S, AuxpoolName),
            if
                AuxWorkStale ->
                    log4erl:debug(db, "~s&~s: Storing ~p&stale share from ~s/~s", [SubpoolName, AuxpoolName, MainState, WorkerName, element(1, Peer)]),
                    store_invalid_share_in_db(WorkerId, UserId, Peer, stale, undefined, Hash, undefined, undefined, undefined, Round, AuxDB),
                    State;
                true ->
                    #auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock} = AuxWork,
                    log4erl:debug(db, "~s&~s: Storing ~p&~p share from ~s/~s", [SubpoolName, AuxpoolName, MainState, AuxState, WorkerName, element(1, Peer)]),
                    case store_share_in_db(WorkerId, UserId, Peer, AuxState, AuxHash, Hash, AuxTarget, AuxBlockNum, AuxPrevBlock, BData, AuxRound, AuxDB) of
                        ok ->
                            store_view_update(AuxDB, Now, State);
                        _ ->
                            State
                    end
            end;
        _ ->
            log4erl:debug(db, "~s: Storing ~p share from ~s/~s", [SubpoolName, MainState, WorkerName, element(1, Peer)]),
            State
    end,
    
    {ok, DB} = couchbeam:open_db(S, SubpoolName),
    case store_share_in_db(WorkerId, UserId, Peer, MainState, Hash, Target, BlockNum, PrevBlock, BData, Round, DB) of
        ok ->
            {noreply, store_view_update(DB, Now, NewState)};
        _ ->
            {noreply, NewState}
    end;

handle_cast({store_invalid_share, #subpool{name=SubpoolName, round=Round, aux_pool=Auxpool}, Peer, #worker{id=WorkerId, user_id=UserId, name=WorkerName}, Workunit, Hash, Reason}, State=#state{srv_conn=S}) ->
    % This code will change if multi aux chains are supported
    case Auxpool of
        #auxpool{name=AuxpoolName, round=AuxRound} ->
            log4erl:debug(db, "~s&~s: Storing invalid share from ~s/~s, reason: ~p", [SubpoolName, AuxpoolName, WorkerName, element(1, Peer), Reason]),
            {ok, AuxDB} = couchbeam:open_db(S, AuxpoolName),
            case Workunit of
                #workunit{aux_work=#auxwork{aux_hash=AuxHash, target=AuxTarget, block_num=AuxBlockNum, prev_block=AuxPrevBlock}} ->
                    store_invalid_share_in_db(WorkerId, UserId, Peer, Reason, AuxHash, Hash, AuxTarget, AuxBlockNum, AuxPrevBlock, AuxRound, AuxDB);
                _ ->
                    store_invalid_share_in_db(WorkerId, UserId, Peer, Reason, undefined, Hash, undefined, undefined, undefined, Round, AuxDB)
            end;
        _ ->
            log4erl:debug(db, "~s: Storing invalid share from ~s/~s, reason: ~p", [SubpoolName, WorkerName, element(1, Peer), Reason]),
            ok
    end,
    
    {ok, DB} = couchbeam:open_db(S, SubpoolName),
    case Workunit of
        #workunit{target=Target, block_num=BlockNum, prev_block=PrevBlock} ->
            store_invalid_share_in_db(WorkerId, UserId, Peer, Reason, Hash, Target, BlockNum, PrevBlock, Round, DB);
        _ ->
            store_invalid_share_in_db(WorkerId, UserId, Peer, Reason, Hash, undefined, undefined, undefined, Round, DB)
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
                    log4erl:info(db, "View updates disabled."),
                    {noreply, State#state{view_update_interval=0, view_update_timer=undefined, view_update_dbs=undefined}};
                _ ->
                    log4erl:info(db, "Set view update timer to ~bs.", [Seconds]),
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
    log4erl:info(db, "View update finished after ~.1fs.", [MS / 1000000]),
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
                couchbeam_view:fetch(DB, {"stats", "state"}),
                couchbeam_view:fetch(DB, {"timed_stats", "all_valids"})
            end,
            DBS
        )
    catch
        exit:Reason ->
            log4erl:error(db, "Exception in do_update_views: ~p", [Reason]);
        error:Reason ->
            log4erl:error(db, "Exception in do_update_views: ~p", [Reason])
    end,
    PID ! view_update_complete.

parse_subpool_document(SubpoolId, {DocProps}) ->
    DocType = proplists:get_value(<<"type">>, DocProps),
    Name = proplists:get_value(<<"name">>, DocProps),
    Port = proplists:get_value(<<"port">>, DocProps),
    PoolType = case proplists:get_value(<<"pool_type">>, DocProps) of
        <<"btc">> -> btc;
        <<"nmc">> -> nmc;
        <<"sc">> -> sc;
        _ -> undefined
    end,
    MaxCacheSize = proplists:get_value(<<"max_cache_size">>, DocProps, 300),
    MaxWorkAge = proplists:get_value(<<"max_work_age">>, DocProps, 20),
    Round = proplists:get_value(<<"round">>, DocProps),
    WorkerShareSubpools = proplists:get_value(<<"worker_share_subpools">>, DocProps, []),
    WorkerShareSubpoolsOk = is_binary_list(WorkerShareSubpools),
    CoinDaemonConfig = case proplists:get_value(<<"coin_daemon">>, DocProps) of
        {CDP} ->
            lists:map(
                fun ({BinName, Value}) -> {binary_to_atom(BinName, utf8), Value} end,
                CDP
            );
        _ ->
            []
    end,
    {AuxPool, AuxPoolOk} = case proplists:get_value(<<"aux_pool">>, DocProps) of
        undefined ->
            {undefined, true};
        AuxPoolDoc ->
            case parse_auxpool_document(AuxPoolDoc) of
                {error, _} -> {undefined, false};
                {ok, AP} -> {AP, true}
            end
    end,
    
    if
        DocType =:= <<"sub-pool">>,
        is_binary(Name),
        Name =/= <<>>,
        is_integer(Port),
        PoolType =/= undefined,
        is_integer(MaxCacheSize),
        is_integer(MaxWorkAge),
        WorkerShareSubpoolsOk,
        AuxPoolOk ->
            
            % Create record
            Subpool = #subpool{
                id=SubpoolId,
                name=Name,
                port=Port,
                pool_type=PoolType,
                max_cache_size=if MaxCacheSize > 0 -> MaxCacheSize; true -> 0 end,
                max_work_age=if MaxWorkAge > 1 -> MaxWorkAge; true -> 1 end,
                round=if is_integer(Round) -> Round; true -> undefined end,
                worker_share_subpools=WorkerShareSubpools,
                coin_daemon_config=CoinDaemonConfig,
                aux_pool=AuxPool
            },
            {ok, Subpool};
        
        true ->
            {error, invalid}
    end.

parse_auxpool_document({DocProps}) ->
    % % DocType = proplists:get_value(<<"type">>, DocProps),
    Name = proplists:get_value(<<"name">>, DocProps),
    PoolType = case proplists:get_value(<<"pool_type">>, DocProps) of
        <<"btc">> -> btc;
        <<"nmc">> -> nmc;
        <<"sc">> -> sc;
        _ -> undefined
    end,
    Round = proplists:get_value(<<"round">>, DocProps),
    AuxDaemonConfig = case proplists:get_value(<<"aux_daemon">>, DocProps) of
        {CDP} ->
            lists:map(
                fun ({BinName, Value}) -> {binary_to_atom(BinName, utf8), Value} end,
                CDP
            );
        _ ->
            []
    end,
    
    if
        % % DocType =:= <<"aux-pool">>,
        is_binary(Name),
        Name =/= <<>>,
        PoolType =/= undefined ->
            
            % Create record
            Auxpool = #auxpool{
                % % id=AuxpoolId,
                name=Name,
                pool_type=PoolType,
                round=if is_integer(Round) -> Round; true -> undefined end,
                aux_daemon_config=AuxDaemonConfig
            },
            {ok, Auxpool};
        
        true ->
            {error, invalid}
    end.

parse_worker_document(WorkerId, {DocProps}) ->
    DocType = proplists:get_value(<<"type">>, DocProps),
    UserId = proplists:get_value(<<"user_id">>, DocProps, null),
    SubpoolId = proplists:get_value(<<"sub_pool_id">>, DocProps),
    Name = proplists:get_value(<<"name">>, DocProps),
    Pass = proplists:get_value(<<"pass">>, DocProps, null),
    LP = proplists:get_value(<<"lp">>, DocProps, true),
    LPHeartbeat = proplists:get_value(<<"lp_heartbeat">>, DocProps, true),
    
    if
        DocType =:= <<"worker">>,
        is_binary(SubpoolId),
        SubpoolId =/= <<>>,
        is_binary(Name),
        Name =/= <<>>,
        is_binary(Pass) or (Pass =:= null),
        is_boolean(LP),
        is_boolean(LPHeartbeat) ->
            
            % Create record
            Worker = #worker{
                id=WorkerId,
                user_id=UserId,
                sub_pool_id=SubpoolId,
                name=Name,
                pass=Pass,
                lp=LP,
                lp_heartbeat=LPHeartbeat
            },
            {ok, Worker};
        
        true ->
            {error, invalid}
    end.

-spec make_share_document(WorkerId :: binary(), UserId :: term(), Peer :: peer(), State :: valid | candidate, Hash :: binary(), ParentHash :: binary() | undefined, Target :: binary(), BlockNum :: integer(), PrevBlock :: binary(), BData :: binary(), Round :: integer()) -> {[]}.
make_share_document(WorkerId, UserId, {IP, UserAgent}, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:universal_time(),
    filter_undefined({[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"user_agent">>, apply_if_defined(UserAgent, fun binary:list_to_bin/1)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, case State of valid -> <<"valid">>; candidate -> <<"candidate">> end},
        {<<"hash">>, ecoinpool_util:bin_to_hexbin(Hash)},
        {<<"parent_hash">>, apply_if_defined(ParentHash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"target">>, ecoinpool_util:bin_to_hexbin(Target)},
        {<<"block_num">>, BlockNum},
        {<<"prev_block">>, apply_if_defined(PrevBlock, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"round">>, Round},
        {<<"data">>, case State of valid -> undefined; candidate -> base64:encode(BData) end}
    ]}).

-spec make_reject_share_document(WorkerId :: binary(), UserId :: term(), Peer :: peer(), Reason :: reject_reason(), Hash :: binary() | undefined, ParentHash :: binary() | undefined, Target :: binary() | undefined, BlockNum :: integer() | undefined, PrevBlock :: binary() | undefined, Round :: integer()) -> {[]}.
make_reject_share_document(WorkerId, UserId, {IP, UserAgent}, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:universal_time(),
    filter_undefined({[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"user_agent">>, apply_if_defined(UserAgent, fun binary:list_to_bin/1)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, <<"invalid">>},
        {<<"reject_reason">>, atom_to_binary(Reason, latin1)},
        {<<"hash">>, apply_if_defined(Hash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"parent_hash">>, apply_if_defined(ParentHash, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"target">>, apply_if_defined(Target, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"block_num">>, BlockNum},
        {<<"prev_block">>, apply_if_defined(PrevBlock, fun ecoinpool_util:bin_to_hexbin/1)},
        {<<"round">>, Round}
    ]}).

apply_if_defined(undefined, _) ->
    undefined;
apply_if_defined(Value, Fun) ->
    Fun(Value).

filter_undefined({DocProps}) ->
    {lists:filter(fun ({_, undefined}) -> false; (_) -> true end, DocProps)}.

is_binary_list(List) when is_list(List) ->
    lists:all(fun erlang:is_binary/1, List);
is_binary_list(_) ->
    false.

store_share_in_db(WorkerId, UserId, Peer, State, Hash, Target, BlockNum, PrevBlock, BData, Round, DB) ->
    store_share_in_db(WorkerId, UserId, Peer, State, Hash, undefined, Target, BlockNum, PrevBlock, BData, Round, DB).

store_share_in_db(WorkerId, UserId, Peer, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round, DB) ->
    Doc = make_share_document(WorkerId, UserId, Peer, State, Hash, ParentHash, Target, BlockNum, PrevBlock, BData, Round),
    try
        couchbeam:save_doc(DB, Doc),
        ok
    catch error:Reason ->
        log4erl:warn(db, "store_share_in_db: ignored error:~n~p", [Reason]),
        error
    end.

-spec store_invalid_share_in_db(WorkerId :: binary(), UserId :: term(), Peer :: peer(), Reason :: reject_reason(), Hash :: binary() | undefined, Target :: binary() | undefined, BlockNum :: integer() | undefined, PrevBlock :: binary() | undefined, Round :: integer(), DB :: tuple()) -> ok | error.
store_invalid_share_in_db(WorkerId, UserId, Peer, Reason, Hash, Target, BlockNum, PrevBlock, Round, DB) ->
    store_invalid_share_in_db(WorkerId, UserId, Peer, Reason, Hash, undefined, Target, BlockNum, PrevBlock, Round, DB).

-spec store_invalid_share_in_db(WorkerId :: binary(), UserId :: term(), Peer :: peer(), Reason :: reject_reason(), Hash :: binary() | undefined, ParentHash :: binary() | undefined, Target :: binary() | undefined, BlockNum :: integer() | undefined, PrevBlock :: binary() | undefined, Round :: integer(), DB :: tuple()) -> ok | error.
store_invalid_share_in_db(WorkerId, UserId, Peer, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round, DB) ->
    Doc = make_reject_share_document(WorkerId, UserId, Peer, Reason, Hash, ParentHash, Target, BlockNum, PrevBlock, Round),
    try
        couchbeam:save_doc(DB, Doc),
        ok
    catch error:Reason ->
        log4erl:warn(db, "store_invalid_share_in_db: ignored error:~n~p", [Reason]),
        error
    end.

store_view_update(_, _, State=#state{view_update_dbs=undefined}) ->
    State;
store_view_update(DB, TS, State=#state{view_update_dbs=ViewUpdateDBS}) ->
    State#state{view_update_dbs=dict:store(DB, TS, ViewUpdateDBS)}.
