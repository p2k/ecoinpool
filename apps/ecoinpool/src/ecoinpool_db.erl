
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

-include("ecoinpool_db_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([start_link/1, get_configuration/0, get_subpool_record/1, get_worker_record/1, get_workers_for_subpools/1, setup_shares_db/1, store_share/5, store_invalid_share/4, store_invalid_share/6]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    srv_conn,
    conf_db
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link({DBHost, DBPort, DBPrefix, DBOptions}) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [{DBHost, DBPort, DBPrefix, DBOptions}], []).

get_configuration() ->
    gen_server:call(?MODULE, get_configuration).

get_subpool_record(SubpoolId) ->
    gen_server:call(?MODULE, {get_subpool_record, SubpoolId}).

get_worker_record(WorkerId) ->
    gen_server:call(?MODULE, {get_worker_record, WorkerId}).

get_workers_for_subpools(SubpoolIds) ->
    gen_server:call(?MODULE, {get_workers_for_subpools, SubpoolIds}).

setup_shares_db(Subpool) ->
    gen_server:call(?MODULE, {setup_shares_db, Subpool}).

store_share(Subpool, IP, Worker, Workunit, Hash) ->
    gen_server:call(?MODULE, {store_share, Subpool, IP, Worker, Workunit, Hash}).

store_invalid_share(Subpool, IP, Worker, Reason) ->
    store_invalid_share(Subpool, IP, Worker, undefined, undefined, Reason).

store_invalid_share(Subpool, IP, Worker, Workunit, Hash, Reason) ->
    gen_server:cast(?MODULE, {store_invalid_share, Subpool, IP, Worker, Workunit, Hash, Reason}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([{DBHost, DBPort, DBPrefix, DBOptions}]) ->
    % Connect to database
    S = couchbeam:server_connection(DBHost, DBPort, DBPrefix, DBOptions),
    % Open database
    ConfDb = case couchbeam:db_exists(S, "ecoinpool") of
        true ->
            {ok, TheConfDb} = couchbeam:open_db(S, "ecoinpool"),
            TheConfDb;
        _ ->
            case couchbeam:create_db(S, "ecoinpool") of
                {ok, NewConfDb} -> % Create basic views
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
                            {<<"by_name">>, {[{<<"map">>, <<"function(doc) {if (doc.type === \"worker\") emit(doc.name, doc.sub_pool_id);}">>}]}}
                        ]}}
                    ]}),
                    io:format("ecoinpool_db: Config database created!~n"),
                    NewConfDb;
                {error, Error} ->
                    io:format("couchbeam:open_or_create_db/3 returned an error: ~p~n", [Error]), throw({error, Error})
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
            ActiveSubpoolIdsCheck = lists:all(fun is_binary/1, ActiveSubpoolIds),
            
            if % Validate data
                DocType =:= <<"configuration">>,
                ActiveSubpoolIdsCheck ->
                    % Create record
                    Configuration = #configuration{active_subpools=ActiveSubpoolIds},
                    {reply, {ok, Configuration}, State};
                true ->
                    {reply, {error, invalid}, State}
            end;
            
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_subpool_record, SubpoolId}, _From, State=#state{conf_db=ConfDb}) ->
    % Retrieve document
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
                    io:format("ecoinpool_db:get_workers_for_subpools: Invalid document for worker ID: ~p.", [Id]),
                    AccWorkers
            end
        end,
        [],
        Rows
    ),
    {reply, Workers, State};

handle_call({setup_shares_db, #subpool{name=SubpoolName}}, _From, State=#state{srv_conn=S}) ->
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
                                {<<"map">>, <<"function(doc) {if (doc.state === \"invalid\") emit([doc.reject_reason, doc.user_id, doc.worker_id], 1);}">>},
                                {<<"reduce">>, <<"function(keys, values, rereduce) {return sum(values);}">>}
                            ]}}
                        ]}}
                    ]}),
                    io:format("ecoinpool_db: Shares database \"~s\" created!~n", [SubpoolName]),
                    {reply, ok, State};
                {error, Error} ->
                    io:format("setup_share_db - couchbeam:open_or_create_db/3 returned an error: ~p~n", [Error]),
                    {reply, error, State}
            end
    end;

handle_call({store_share, #subpool{name=SubpoolName}, IP, #worker{id=WorkerId, user_id=UserId}, #workunit{target=Target, block_num=BlockNum, data=BData}, Hash}, _From, State=#state{srv_conn=S}) ->
    try
        {ok, DB} = couchbeam:open_db(S, SubpoolName),
        if
            Hash =< Target ->
                couchbeam:save_doc(DB, make_share_document(WorkerId, UserId, IP, candidate, Hash, Target, BlockNum, BData)),
                {reply, candidate, State};
            true ->
                couchbeam:save_doc(DB, make_share_document(WorkerId, UserId, IP, valid, Hash, Target, BlockNum)),
                {reply, ok, State}
        end
    catch error:_ ->
        {reply, error, State}
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

handle_cast({store_invalid_share, #subpool{name=SubpoolName}, IP, #worker{id=WorkerId, user_id=UserId}, Workunit, Hash, Reason}, State=#state{srv_conn=S}) ->
    Document = case Workunit of
        undefined ->
            make_reject_share_document(WorkerId, UserId, IP, Reason);
        #workunit{target=Target, block_num=BlockNum} ->
            make_reject_share_document(WorkerId, UserId, IP, Reason, Hash, Target, BlockNum)
    end,
    try
        {ok, DB} = couchbeam:open_db(S, SubpoolName),
        couchbeam:save_doc(DB, Document)
    catch error:_ ->
        ok
    end,
    {noreply, State};

handle_cast(_Message, State=#state{}) ->
    {noreply, State}.

handle_info(_Message, State=#state{}) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State=#state{}, _Extra) ->
    {ok, State}.

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
    CoinDaemonConfig = case proplists:get_value(<<"coin_daemon">>, DocProps) of
        {CDP} ->
            lists:map(
                fun ({BinName, Value}) -> {binary_to_atom(BinName, utf8), Value} end,
                CDP
            );
        _ ->
            []
    end,
    
    if
        DocType =:= <<"sub-pool">>,
        is_binary(Name),
        Name =/= <<>>,
        is_integer(Port),
        PoolType =/= undefined ->
            
            % Create record
            Subpool = #subpool{
                id=SubpoolId,
                name=Name,
                port=Port,
                pool_type=PoolType,
                coin_daemon_config=CoinDaemonConfig
            },
            {ok, Subpool};
        
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
    
    if
        DocType =:= <<"worker">>,
        is_binary(SubpoolId),
        SubpoolId =/= <<>>,
        is_binary(Name),
        Name =/= <<>>,
        is_binary(Pass) or (Pass =:= null),
        is_boolean(LP) ->
            
            % Create record
            Worker = #worker{
                id=WorkerId,
                user_id=UserId,
                sub_pool_id=SubpoolId,
                name=Name,
                pass=Pass,
                lp=LP
            },
            {ok, Worker};
        
        true ->
            {error, invalid}
    end.

make_share_document(WorkerId, UserId, IP, State, Hash, Target, BlockNum) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:universal_time(),
    {[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, State},
        {<<"hash">>, ecoinpool_util:bin_to_hexbin(Hash)},
        {<<"target">>, ecoinpool_util:bin_to_hexbin(Target)},
        {<<"block_num">>, BlockNum}
    ]}.

make_share_document(WorkerId, UserId, IP, State, Hash, Target, BlockNum, BData) ->
    {Doc} = make_share_document(WorkerId, UserId, IP, State, Hash, Target, BlockNum),
    {Doc ++ [{<<"data">>, base64:encode(BData)}]}.

make_reject_share_document(WorkerId, UserId, IP, Reason) ->
    {{YR,MH,DY}, {HR,ME,SD}} = calendar:universal_time(),
    {[
        {<<"worker_id">>, WorkerId},
        {<<"user_id">>, UserId},
        {<<"ip">>, binary:list_to_bin(IP)},
        {<<"timestamp">>, [YR,MH,DY,HR,ME,SD]},
        {<<"state">>, <<"invalid">>},
        {<<"reject_reason">>, atom_to_binary(Reason, latin1)}
    ]}.

make_reject_share_document(WorkerId, UserId, IP, Reason, Hash, Target, BlockNum) ->
    {Doc} = make_reject_share_document(WorkerId, UserId, IP, Reason),
    {Doc ++ [
        {<<"hash">>, ecoinpool_util:bin_to_hexbin(Hash)},
        {<<"target">>, ecoinpool_util:bin_to_hexbin(Target)},
        {<<"block_num">>, BlockNum}
    ]}.
