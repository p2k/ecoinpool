
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
    get_couchdb_connection/0,
    get_configuration/0,
    get_subpool_record/1,
    get_worker_record/1,
    get_workers_for_subpools/1,
    set_subpool_round/2,
    set_auxpool_round/2,
    setup_sub_pool_user_id/3,
    update_site/0
]).

-export([parse_configuration_document/1, parse_subpool_document/1, parse_worker_document/1, check_design_doc/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    srv_conn,
    conf_db
}).

%% ===================================================================
%% API functions
%% ===================================================================

-spec start_link({DBHost :: string(), DBPort :: integer(), DBPrefix :: string(), DBOptions :: [term()]}) -> {ok, pid()} | ignore | {error, {already_started, pid()} | term()}.
start_link({DBHost, DBPort, DBPrefix, DBOptions}) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [{DBHost, DBPort, DBPrefix, DBOptions}], []).

-spec get_couchdb_connection() -> term().
get_couchdb_connection() ->
    gen_server:call(?MODULE, get_couchdb_connection).

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

-spec setup_sub_pool_user_id(SubpoolId :: binary(), UserName :: binary(), Callback :: fun(({ok, UserId :: integer()} | {error, Reason :: binary()}) -> any())) -> ok.
setup_sub_pool_user_id(SubpoolId, UserName, Callback) ->
    gen_server:cast(?MODULE, {setup_sub_pool_user_id, SubpoolId, UserName, Callback}).

-spec update_site() -> ok.
update_site() ->
    gen_server:cast(?MODULE, update_site).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([{DBHost, DBPort, DBPrefix, DBOptions}]) ->
    % Trap exit
    process_flag(trap_exit, true),
    % Create server connection
    S = couchbeam:server_connection(DBHost, DBPort, DBPrefix, DBOptions),
    % Setup users database
    {ok, UsersDb} = couchbeam:open_db(S, "_users"),
    check_design_doc({UsersDb, "ecoinpool", "users_db_ecoinpool.json"}),
    % Open and setup config database
    ConfDb = case couchbeam:open_or_create_db(S, "ecoinpool") of
        {ok, DB} ->
            lists:foreach(fun check_design_doc/1, [
                {DB, "doctypes", "main_db_doctypes.json"},
                {DB, "workers", "main_db_workers.json"},
                {DB, "auth", "main_db_auth.json"},
                {DB, "site", "main_db_site.json"}
            ]),
            DB;
        {error, Error} ->
            log4erl:fatal(db, "config_db - couchbeam:open_or_create_db/3 returned an error:~n~p", [Error]), throw({error, Error})
    end,
    % Start config & worker monitor (asynchronously)
    gen_server:cast(?MODULE, start_monitors),
    % Return initial state
    {ok, #state{srv_conn=S, conf_db=ConfDb}}.

handle_call(get_couchdb_connection, _From, State=#state{srv_conn=S}) ->
    {reply, S, State};

handle_call(get_configuration, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, "configuration") of
        {ok, Doc} ->
            {reply, parse_configuration_document(Doc), State};
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_subpool_record, SubpoolId}, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, SubpoolId) of
        {ok, Doc} ->
            {reply, parse_subpool_document(Doc), State};
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_worker_record, WorkerId}, _From, State=#state{conf_db=ConfDb}) ->
    case couchbeam:open_doc(ConfDb, WorkerId) of
        {ok, Doc} ->
            {reply, parse_worker_document(Doc), State};
        _ ->
            {reply, {error, missing}, State}
    end;

handle_call({get_workers_for_subpools, SubpoolIds}, _From, State=#state{conf_db=ConfDb}) ->
    {ok, Rows} = couchbeam_view:fetch(ConfDb, {"workers", "by_sub_pool"}, [include_docs, {keys, SubpoolIds}]),
    Workers = lists:foldl(
        fun ({RowProps}, AccWorkers) ->
            Id = proplists:get_value(<<"id">>, RowProps),
            Doc = proplists:get_value(<<"doc">>, RowProps),
            case parse_worker_document(Doc) of
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

handle_cast({setup_sub_pool_user_id, SubpoolId, UserName, Callback}, State=#state{srv_conn=S}) ->
    {ok, UsersDB} = couchbeam:open_db(S, "_users"),
    case couchbeam:open_doc(UsersDB, <<"org.couchdb.user:", UserName/binary>>) of
        {ok, Doc} ->
            case couchbeam_view:fetch(UsersDB, {"ecoinpool", "user_ids"}, [{key, [SubpoolId, UserName]}]) of
                {ok, []} ->
                    NewUserId = case couchbeam_view:fetch(UsersDB, {"ecoinpool", "user_ids"}, [{start_key, [SubpoolId]}, {end_key, [SubpoolId, {[]}]}]) of
                        {ok, []} -> 1;
                        {ok, [{RowProps}]} -> proplists:get_value(<<"value">>, RowProps, 0) + 1
                    end,
                    NewUserIdBin = list_to_binary(integer_to_list(NewUserId)),
                    NewRoles = [<<"user_id:", SubpoolId/binary, $:, NewUserIdBin/binary>> | couchbeam_doc:get_value(<<"roles">>, Doc, [])],
                    catch couchbeam:save_doc(UsersDB, couchbeam_doc:set_value(<<"roles">>, NewRoles, Doc)),
                    log4erl:info(db, "setup_sub_pool_user_id: Setup new user ID ~b for username \"~s\" in subpool \"~s\"", [NewUserId, UserName, SubpoolId]),
                    Callback({ok, NewUserId});
                {ok, [{RowProps}]} ->
                    Callback({ok, proplists:get_value(<<"value">>, RowProps)});
                _ ->
                    log4erl:warn(db, "setup_sub_pool_user_id: Not supported by this pool"),
                    Callback({error, <<"not supported by this pool">>})
            end;
        _ ->
            log4erl:warn(db, "setup_sub_pool_user_id: Username \"~s\" does not exist", [UserName]),
            Callback({error, <<"username does not exist">>})
    end,
    {noreply, State};

handle_cast(update_site, State=#state{conf_db=ConfDb}) ->
    {ok, SDoc} = file:read_file(filename:join(code:priv_dir(ecoinpool), "main_db_site.json")),
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

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{}) ->
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
            {ok, SDoc} = file:read_file(filename:join(code:priv_dir(ecoinpool), Filename)),
            {ok, _} = couchbeam:save_doc(DB, ejson:decode(SDoc)),
            ok
    end.

parse_configuration_document({DocProps}) ->
    DocType = proplists:get_value(<<"type">>, DocProps),
    ActiveSubpoolIds = proplists:get_value(<<"active_subpools">>, DocProps, []),
    ActiveSubpoolIdsCheck = if is_list(ActiveSubpoolIds) -> lists:all(fun is_binary/1, ActiveSubpoolIds); true -> false end,
    ShareLoggers = case proplists:get_value(<<"share_loggers">>, DocProps) of
        undefined ->
            [{<<"default_couchdb">>, <<"couchdb">>, []}, {<<"default_logfile">>, <<"logfile">>, []}];
        {Props} ->
            lists:foldr(
                fun
                    ({Id, Type}, Acc) when is_binary(Type) ->
                        [{Id, Type, []} | Acc];
                    ({Id, {LoggerProps}}, Acc) ->
                        case proplists:get_value(<<"type">>, LoggerProps) of
                            Type when is_binary(Type) ->
                                Config = [{binary_to_atom(BinName, utf8), Value} || {BinName, Value} <- proplists:delete(<<"type">>, LoggerProps)],
                                [{Id, Type, Config} | Acc];
                            _ ->
                                Acc
                        end;
                    (_, Acc) ->
                        Acc
                end,
                [],
                Props
            );
        _ ->
            []
    end,
    
    if
        DocType =:= <<"configuration">>,
        ActiveSubpoolIdsCheck ->
            
            % Create record
            Configuration = #configuration{
                active_subpools=ActiveSubpoolIds,
                share_loggers=ShareLoggers
            },
            {ok, Configuration};
        true ->
            {error, invalid}
    end.

parse_subpool_document({DocProps}) ->
    SubpoolId = proplists:get_value(<<"_id">>, DocProps),
    DocType = proplists:get_value(<<"type">>, DocProps),
    Name = proplists:get_value(<<"name">>, DocProps),
    Port = proplists:get_value(<<"port">>, DocProps),
    PoolType = case proplists:get_value(<<"pool_type">>, DocProps) of
        <<"btc">> -> btc;
        <<"ltc">> -> ltc;
        <<"fbx">> -> fbx;
        <<"sc">> -> sc;
        _ -> undefined
    end,
    MaxCacheSize = proplists:get_value(<<"max_cache_size">>, DocProps, 20),
    MaxWorkAge = proplists:get_value(<<"max_work_age">>, DocProps, 20),
    AcceptWorkers = case proplists:get_value(<<"accept_workers">>, DocProps) of
        <<"registered">> ->
            registered;
        <<"valid_address">> ->
            valid_address;
        <<"any">> ->
            any;
        undefined ->
            registered;
        _ ->
            invalid
    end,
    LowercaseWorkers = proplists:get_value(<<"lowercase_workers">>, DocProps, true),
    IgnorePasswords = proplists:get_value(<<"ignore_passwords">>, DocProps, true),
    RollNTime = proplists:get_value(<<"rollntime">>, DocProps, true),
    Round = proplists:get_value(<<"round">>, DocProps),
    WorkerShareSubpools = proplists:get_value(<<"worker_share_subpools">>, DocProps, []),
    WorkerShareSubpoolsOk = is_binary_list(WorkerShareSubpools),
    CoinDaemonConfig = case proplists:get_value(<<"coin_daemon">>, DocProps) of
        {CDP} -> [{binary_to_atom(BinName, utf8), Value} || {BinName, Value} <- CDP];
        _ -> []
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
        AcceptWorkers =/= invalid,
        is_boolean(LowercaseWorkers),
        is_boolean(IgnorePasswords),
        is_boolean(RollNTime),
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
                accept_workers=AcceptWorkers,
                lowercase_workers=LowercaseWorkers,
                ignore_passwords=IgnorePasswords,
                rollntime=RollNTime,
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
        <<"nmc">> -> nmc;
        _ -> undefined
    end,
    Round = proplists:get_value(<<"round">>, DocProps),
    AuxDaemonConfig = case proplists:get_value(<<"aux_daemon">>, DocProps) of
        {CDP} -> [{binary_to_atom(BinName, utf8), Value} || {BinName, Value} <- CDP];
        _ -> []
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

parse_worker_document({DocProps}) ->
    WorkerId = proplists:get_value(<<"_id">>, DocProps),
    DocType = proplists:get_value(<<"type">>, DocProps),
    UserId = proplists:get_value(<<"user_id">>, DocProps),
    SubpoolId = proplists:get_value(<<"sub_pool_id">>, DocProps),
    Name = proplists:get_value(<<"name">>, DocProps),
    Pass = ecoinpool_util:parse_json_password(proplists:get_value(<<"pass">>, DocProps)),
    LP = proplists:get_value(<<"lp">>, DocProps, true),
    LPHeartbeat = proplists:get_value(<<"lp_heartbeat">>, DocProps, true),
    AuxLP = proplists:get_value(<<"aux_lp">>, DocProps, true),
    
    if
        DocType =:= <<"worker">>,
        is_binary(SubpoolId),
        SubpoolId =/= <<>>,
        is_binary(Name),
        Name =/= <<>>,
        is_binary(Pass) or (Pass =:= undefined),
        is_boolean(LP),
        is_boolean(LPHeartbeat),
        is_boolean(AuxLP) ->
            
            % Create record
            Worker = #worker{
                id=WorkerId,
                user_id=UserId,
                sub_pool_id=SubpoolId,
                name=Name,
                pass=Pass,
                lp=LP,
                lp_heartbeat=LPHeartbeat,
                aux_lp=AuxLP
            },
            {ok, Worker};
        
        true ->
            {error, invalid}
    end.

is_binary_list(List) when is_list(List) ->
    lists:all(fun erlang:is_binary/1, List);
is_binary_list(_) ->
    false.
