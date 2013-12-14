
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

-module(ecoinpool_server).
-behaviour(gen_server).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([
    start_link/1,
    reload_config/1,
    coindaemon_ready/2,
    auxdaemon_ready/3,
    update_worker/2,
    remove_worker/2,
    get_worker_notifications/1,
    store_workunit/2,
    new_block_detected/1,
    new_aux_block_detected/2
]).

% Callback from ecoinpool_rpc
-export([rpc_request/2]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool :: subpool(),
    cdaemon :: abstract_coindaemon(),
    mmm :: mmm(),
    gw_method :: atom(),
    sw_method :: atom(),
    share_target :: binary(),
    workq :: queue(),
    workq_size :: integer(),
    worktbl :: ets:tid(),
    hashtbl :: ets:tid(),
    workertbl :: ets:tid(),
    workerltbl :: ets:tid(),
    lp_queue :: [{worker(), ecoinpool_rpc_request()}]
}).

-define(TEST_UNAUTH_MESSAGE, <<"Yes, the server is online! So the problem is either your miner, your ISP or sitting between chair and keyboard.">>).
-define(TEST_ACCEPT_MESSAGE, <<"Yes, the server is online and your credentials were accepted! So the problem is either your miner, your ISP or sitting between chair and keyboard.">>).
-define(TEST_REJECT_MESSAGE, <<"The server is online but you must have misspelled your worker name and/or password or the worker doesn't exist.">>).
-define(TEST_REJECT_ADDRESS_MESSAGE, <<"The server is online but you must have misspelled your payout address.">>).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(SubpoolId) ->
    gen_server:start_link({global, {?MODULE, SubpoolId}}, ?MODULE, [SubpoolId], []).

reload_config(Subpool=#subpool{id=SubpoolId}) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {reload_config, Subpool}).

coindaemon_ready(SubpoolId, PID) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {coindaemon_ready, PID}).

auxdaemon_ready(SubpoolId, Module, PID) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {auxdaemon_ready, Module, PID}).

rpc_request(PID, Req) ->
    gen_server:cast(PID, {rpc_request, Req}).

update_worker(SubpoolId, Worker) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {update_worker, Worker}).

remove_worker(SubpoolId, WorkerId) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {remove_worker, WorkerId}).

% Returns a list of sub-pools for which notifications should be sent
% For simple configurations, this just returns the SubpoolId again, but for
% multi-pool-configurations this may return a longer list
get_worker_notifications(SubpoolId) ->
    gen_server:call({global, {?MODULE, SubpoolId}}, get_worker_notifications).

store_workunit(SubpoolId, Workunit) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {store_workunit, Workunit}).

new_block_detected(SubpoolId) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {new_block_detected, main}).

new_aux_block_detected(SubpoolId, _Module) ->
    gen_server:cast({global, {?MODULE, SubpoolId}}, {new_block_detected, aux}).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

-spec init([binary(), ...]) -> {ok, #state{}}.
init([SubpoolId]) ->
    log4erl:warn(server, "Subpool ~s starting...", [SubpoolId]),
    % Trap exit
    process_flag(trap_exit, true),
    % Get Subpool record; terminate on error
    {ok, Subpool} = ecoinpool_db:get_subpool_record(SubpoolId),
    % Load work and hashes table
    StorageDir = ecoinpool_util:server_storage_dir(SubpoolId),
    WorkTbl = case ets:file2tab(binary_to_list(filename:join(StorageDir, "worktbl.ets")), [{verify, true}]) of
        {ok, Tab1} -> Tab1;
        {error, _} -> ets:new(worktbl, [set, protected, {keypos, #workunit.id}])
    end,
    HashTbl = case ets:file2tab(binary_to_list(filename:join(StorageDir, "hashtbl.ets")), [{verify, true}]) of
        {ok, Tab2} -> Tab2;
        {error, _} -> ets:new(hashtbl, [set, protected])
    end,
    WorkerTbl = ets:new(workertbl, [set, protected, {keypos, #worker.name}]),
    WorkerLookupTbl = ets:new(workerltbl, [set, protected]),
    % Schedule config reload
    gen_server:cast(self(), {reload_config, Subpool}),
    % Create work check timer
    {ok, _} = timer:send_interval(500, check_work_age), % Fixed to twice per second
    {ok, #state{subpool=#subpool{}, workq=queue:new(), workq_size=0, worktbl=WorkTbl, hashtbl=HashTbl, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl, lp_queue=[]}}.

handle_call(get_worker_notifications, _From, State=#state{subpool=Subpool}) ->
    % Returns the sub-pool IDs for which worker changes should be retrieved
    % Note: Currently only returns the own sub-pool ID
    #subpool{id=SubpoolId} = Subpool,
    {reply, [SubpoolId], State};

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({reload_config, Subpool}, State=#state{subpool=OldSubpool, workq_size=WorkQueueSize, cdaemon=OldCoinDaemon, mmm=OldMMM}) ->
    % Extract config
    #subpool{id=SubpoolId, name=SubpoolName, port=Port, pool_type=PoolType, max_cache_size=MaxCacheSize, lowercase_workers=LowercaseWorkers, worker_share_subpools=WorkerShareSubpools, coin_daemon_config=CoinDaemonConfig, aux_pool=Auxpool} = Subpool,
    #subpool{port=OldPort, max_cache_size=OldMaxCacheSize, lowercase_workers=OldLowercaseWorkers, worker_share_subpools=OldWorkerShareSubpools, coin_daemon_config=OldCoinDaemonConfig, aux_pool=OldAuxpool} = OldSubpool,
    % Derive the CoinDaemon module name from PoolType + "_coindaemon", except for SCrypt pools which are all handled by scrypt_coindaemon
    CoinDaemonModule = if
        PoolType =:= ltc ->
            scrypt_coindaemon;
        true ->
            list_to_atom(lists:concat([PoolType, "_coindaemon"]))
    end,
    
    % Schedule workers reload if worker_share_subpools changed
    % Note: this includes an initial load, because even if no share subpools
    %   are specified, this will at least be an empty list =/= undefined.
    if
        WorkerShareSubpools =/= OldWorkerShareSubpools;
        LowercaseWorkers =/= OldLowercaseWorkers ->
            gen_server:cast(self(), reload_workers);
        true ->
            ok
    end,
    
    % Check the RPC settings; if anything goes wrong, terminate
    StartRPC = if
        OldPort =:= Port -> false;
        OldPort =:= undefined -> true;
        true -> ecoinpool_rpc:stop_rpc(OldPort), true
    end,
    ok = if
        StartRPC -> ecoinpool_rpc:start_rpc(Port, self());
        true -> ok
    end,
    
    % Check the CoinDaemon; if anything goes wrong, terminate
    OldCoinDaemonModule = case OldCoinDaemon of
        undefined -> undefined;
        _ -> OldCoinDaemon:coindaemon_module()
    end,
    StartCoinDaemon = if
        OldCoinDaemonModule =:= CoinDaemonModule, OldCoinDaemonConfig =:= CoinDaemonConfig -> false;
        OldCoinDaemonModule =:= undefined -> true;
        true -> ecoinpool_server_sup:stop_coindaemon(SubpoolId), true
    end,
    {ok, CoinDaemon} = if
        StartCoinDaemon ->
            case ecoinpool_server_sup:start_coindaemon(SubpoolId, CoinDaemonModule, [{pool_type, PoolType} | CoinDaemonConfig]) of
                {ok, NewCoinDaemon} -> {ok, NewCoinDaemon};
                Error -> log4erl:fatal(server, "~s: Could not start CoinDaemon!", [SubpoolName]), ecoinpool_rpc:stop_rpc(Port), Error % Fail but close the RPC beforehand
            end;
        true -> {ok, OldCoinDaemon}
    end,
    GetworkMethod = CoinDaemon:getwork_method(),
    SendworkMethod = CoinDaemon:sendwork_method(),
    ShareTarget = CoinDaemon:share_target(),
    
    % Check the aux pool configuration
    MMM = check_aux_pool_config(SubpoolName, SubpoolId, OldAuxpool, OldMMM, Auxpool, StartCoinDaemon),
    CoinDaemon:set_mmm(MMM),
    
    % Check cache settings
    if
        not StartCoinDaemon, % CoinDaemon was already running
        WorkQueueSize =:= OldMaxCacheSize, % Cache was full
        WorkQueueSize < MaxCacheSize -> % But too few entries on new setting
            log4erl:debug(server, "~s: reload_config: cache size changed from ~b to ~b requesting more work.", [SubpoolName, OldMaxCacheSize, MaxCacheSize]),
            CoinDaemon:post_workunit();
        true ->
            ok
    end,
    {noreply, State#state{subpool=Subpool, cdaemon=CoinDaemon, mmm=MMM, gw_method=GetworkMethod, sw_method=SendworkMethod, share_target=ShareTarget}};

handle_cast({coindaemon_ready, PID}, State=#state{subpool=#subpool{max_cache_size=MaxCacheSize}, workq_size=WorkQueueSize, cdaemon=OldCoinDaemon}) ->
    CoinDaemon = OldCoinDaemon:update_pid(PID),
    if % At this point, no request can be running yet; if it should, start it now
        WorkQueueSize < MaxCacheSize ->
            CoinDaemon:post_workunit();
        true ->
            ok
    end,
    % Always trigger a block change here
    handle_cast(new_block_detected, State#state{cdaemon=CoinDaemon});

handle_cast({auxdaemon_ready, Module, PID}, State=#state{subpool=#subpool{name=SubpoolName}, cdaemon=CoinDaemon, mmm=OldMMM}) ->
    case OldMMM:update_aux_daemon(Module, PID) of
        unchanged ->
            {noreply, State};
        MMM ->
            log4erl:info(server, "~s: Got new AuxDaemon process.", [SubpoolName]),
            CoinDaemon:set_mmm(MMM),
            {noreply, State#state{mmm=MMM}}
    end;

handle_cast(reload_workers, State=#state{subpool=Subpool, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    #subpool{id=SubpoolId, name=SubpoolName, lowercase_workers=LowercaseWorkers, worker_share_subpools=WorkerShareSubpools} = Subpool,
    
    ets:delete_all_objects(WorkerLookupTbl),
    ets:delete_all_objects(WorkerTbl),
    
    lists:foreach(
        fun (MixedCaseWorker=#worker{id=WorkerId, sub_pool_id=WorkerSubpoolId, name=MixedCaseWorkerName}) ->
            {Worker, WorkerName} = case LowercaseWorkers of
                true -> LowercaseWorkerName=binary_to_lower(MixedCaseWorkerName), {MixedCaseWorker#worker{name=LowercaseWorkerName}, LowercaseWorkerName};
                false -> {MixedCaseWorker, MixedCaseWorkerName}
            end,
            case ets:insert_new(WorkerTbl, Worker) of
                true ->
                    ets:insert(WorkerLookupTbl, {WorkerId, WorkerName});
                _ ->
                    log4erl:warn(server, "~s: reload_workers: Worker name \"~s\" already taken, ignoring worker \"~s\" of sub-pool \"~s\"!", [SubpoolName, WorkerName, WorkerId, WorkerSubpoolId])
            end
        end,
        ecoinpool_db:get_workers_for_subpools([SubpoolId|WorkerShareSubpools])
    ),
    
    % Register for worker change notifications
    ecoinpool_worker_monitor:set_worker_notifications(SubpoolId, [SubpoolId|WorkerShareSubpools]),
    
    {noreply, State};

handle_cast({rpc_request, Req}, State) ->
    % Extract state variables
    #state{
        subpool=Subpool,
        cdaemon=CoinDaemon,
        mmm=MMM,
        gw_method=GetworkMethod,
        sw_method=SendworkMethod,
        share_target=ShareTarget,
        workq=WorkQueue,
        workq_size=WorkQueueSize,
        worktbl=WorkTbl,
        hashtbl=HashTbl,
        workertbl=WorkerTbl,
        lp_queue=LPQueue
    } = State,
    #subpool{
        id=SubpoolId,
        name=SubpoolName,
        max_cache_size=MaxCacheSize,
        max_work_age=MaxWorkAge,
        accept_workers=AcceptWorkers,
        lowercase_workers=LowercaseWorkers,
        ignore_passwords=IgnorePasswords,
        rollntime=RollNTime
    } = Subpool,
    % Check the method and authentication
    case parse_method_and_auth(Req, SubpoolName, WorkerTbl, GetworkMethod, SendworkMethod, AcceptWorkers, LowercaseWorkers, IgnorePasswords) of
        {ok, Worker=#worker{name=WorkerName, lp_heartbeat=WithHeartbeat}, Action} ->
            LP = Req:get(lp),
            case Action of % Now match for the action
                getwork when LP ->
                    log4erl:info(server, "~s: LP requested by ~s/~s", [SubpoolName, WorkerName, Req:get(ip)]),
                    Req:start(WithHeartbeat, make_response_options(Worker, RollNTime, Req:get(mining_extensions))),
                    {noreply, State#state{lp_queue=[{Worker, Req} | LPQueue]}};
                getwork ->
                    {NewWorkQueue, NewWorkQueueSize} = assign_work(Req, SubpoolName, erlang:now(), MaxWorkAge, MaxCacheSize, RollNTime, Worker, WorkQueue, WorkQueueSize, WorkTbl, CoinDaemon),
                    if
                        WorkQueueSize =:= MaxCacheSize, % Cache was max size
                        NewWorkQueueSize < MaxCacheSize -> % And now is below max size
                            CoinDaemon:post_workunit(); % -> Call for work
                        true ->
                            ok
                    end,
                    {noreply, State#state{workq=NewWorkQueue, workq_size=NewWorkQueueSize}};
                sendwork when not LP ->
                    check_new_round(Subpool, check_work(Req, Subpool, Worker, WorkTbl, HashTbl, CoinDaemon, MMM, ShareTarget)),
                    {noreply, State};
                _ ->
                    Req:error(method_not_found),
                    {noreply, State}
            end;
        {error, Type} ->
            Req:error(Type),
            {noreply, State};
        {setup_user, UserName} ->
            ecoinpool_db:setup_sub_pool_user_id(SubpoolId, UserName, fun ({ok, UserId}) -> Req:ok(UserId, []); ({error, Reason}) -> Req:error({-1, Reason}) end),
            {noreply, State};
        {test, Message} ->
            Req:ok(Message, []),
            {noreply, State}
    end;

handle_cast({new_block_detected, Chain}, State) ->
    % Extract state variables
    #state{
        subpool=#subpool{name=SubpoolName, max_cache_size=MaxCacheSize},
        cdaemon=CoinDaemon,
        workq=WorkQueue,
        workq_size=WorkQueueSize,
        worktbl=WorkTbl,
        hashtbl=HashTbl,
        lp_queue=LPQueue
    } = State,
    log4erl:warn(server, "~s: --- New ~p block! Assigned: ~b; Shares: ~b; Cached: ~b; Longpolling: ~b ---", [SubpoolName, Chain, ets:info(WorkTbl, size), ets:info(HashTbl, size), WorkQueueSize, length(LPQueue)]),
    ReqSource = case Chain of
        main ->
            ets:delete_all_objects(WorkTbl), % Clear the work table
            ets:delete_all_objects(HashTbl), % Clear the duplicate hashes table
            main_lp;
        aux ->
            mark_aux_work_stale(WorkTbl, ets:first(WorkTbl)), % Mark all aux work as stale
            aux_lp
    end,
    % Check if LP are still valid
    CheckedLPQueue = lists:filter(
        fun ({#worker{name=WorkerName}, Req}) ->
            case Req:check() of
                ok ->
                    true;
                _ ->
                    log4erl:debug(server, "~s: LP connection for ~s/~s was dropped, skipping.", [SubpoolName, WorkerName, Req:get(ip)]),
                    false
            end
        end,
        LPQueue
    ),
    % On an aux block, partition the list so users which don't care about it are not notified.
    {FilteredLPQueue, NewLPQueue} = case Chain of
        main ->
            {CheckedLPQueue, []};
        aux ->
            lists:partition(fun ({#worker{aux_lp=AuxLP}, _}) -> AuxLP end, CheckedLPQueue)
    end,
    {NewWorkQueue, NewWorkQueueSize} = case FilteredLPQueue of
        [] ->
            % Empty LP queue -> only discard cache, if present
            if
                WorkQueueSize < 0 ->
                    {WorkQueue, WorkQueueSize};
                true ->
                    {queue:new(), 0}
            end;
        _ ->
            % Add the request source, reverse the list so order is correct and convert to a Erlang queue
            LPWorkQueue = queue:from_list(lists:foldl(
                fun ({Worker, Req}, Acc) -> [{Worker, Req, ReqSource} | Acc] end,
                [],
                FilteredLPQueue
            )),
            if
                WorkQueueSize < 0 -> % Join with existing requests (LP has priority)
                    {queue:join(LPWorkQueue, WorkQueue), WorkQueueSize - length(FilteredLPQueue)};
                true ->
                    {LPWorkQueue, -length(FilteredLPQueue)}
            end
    end,
    if
        WorkQueueSize =:= MaxCacheSize, % Cache was max size
        NewWorkQueueSize < MaxCacheSize -> % And now is below max size
            CoinDaemon:post_workunit(); % -> Call for work
        true ->
            ok
    end,
    {noreply, State#state{workq=NewWorkQueue, workq_size=NewWorkQueueSize, lp_queue=NewLPQueue}};

handle_cast({store_workunit, Workunit}, State) ->
    % Extract state variables
    #state{
        subpool=#subpool{name=SubpoolName, max_cache_size=MaxCacheSize, rollntime=RollNTime},
        cdaemon=CoinDaemon,
        workq=WorkQueue,
        workq_size=WorkQueueSize,
        worktbl=WorkTbl
    } = State,
    % Inspect the Cache/Queue
    {NewWorkQueue, NewWorkQueueSize} = if
        WorkQueueSize < 0 -> % We have connections waiting -> send out
            {{value, {Worker=#worker{id=WorkerId}, Req, ReqSource}}, NWQ} = queue:out(WorkQueue),
            case ets:insert_new(WorkTbl, Workunit#workunit{worker_id=WorkerId}) of
                false -> log4erl:error(server, "~s: store_workunit got a collision :/", [SubpoolName]);
                _ -> ok
            end,
            MiningExtensions = Req:get(mining_extensions),
            EncWorkunit = CoinDaemon:encode_workunit(Workunit, MiningExtensions),
            SendWorkunit = case lists:member(submitold, MiningExtensions) of
                true ->
                    case ReqSource of % Set submitold depending on the request source
                        normal ->
                            EncWorkunit;
                        main_lp ->
                            json_add_value(<<"submitold">>, false, EncWorkunit);
                        aux_lp ->
                            json_add_value(<<"submitold">>, true, EncWorkunit)
                    end;
                _ ->
                    EncWorkunit
            end,
            Req:ok(SendWorkunit, make_response_options(Worker, Workunit, RollNTime, MiningExtensions)),
            {NWQ, WorkQueueSize+1};
        WorkQueueSize < MaxCacheSize -> % We are under the cache limit -> cache
            {queue:in(Workunit, WorkQueue), WorkQueueSize+1};
        true -> % Overflow -> ignore
            {WorkQueue, WorkQueueSize}
    end,
    log4erl:debug(server, "~s:  Queue size: ~b/~b", [SubpoolName, NewWorkQueueSize, MaxCacheSize]),
    if
        NewWorkQueueSize < MaxCacheSize -> % Cache is still below max size
            CoinDaemon:post_workunit(); % -> Call for more work
        true ->
            ok
    end,
    {noreply, State#state{workq=NewWorkQueue, workq_size=NewWorkQueueSize}};

handle_cast({update_worker, MixedCaseWorker=#worker{id=WorkerId, name=MixedCaseWorkerName}}, State=#state{subpool=#subpool{name=SubpoolName, lowercase_workers=LowercaseWorkers}, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    {Worker, WorkerName} = case LowercaseWorkers of
        true -> LowercaseWorkerName=binary_to_lower(MixedCaseWorkerName), {MixedCaseWorker#worker{name=LowercaseWorkerName}, LowercaseWorkerName};
        false -> {MixedCaseWorker, MixedCaseWorkerName}
    end,
    % Check if existing
    case ets:lookup(WorkerLookupTbl, WorkerId) of
        [] -> % Brand new
            log4erl:info(server, "~s: Adding new worker \"~s\".", [SubpoolName, WorkerName]),
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName});
        [{_, WorkerName}] -> % Existing and worker name matches
            log4erl:info(server, "~s: Updating worker \"~s\".", [SubpoolName, WorkerName]);
        [{_, OldWorkerName}] -> % Existing & name change
            log4erl:info(server, "~s: Updating worker \"~s\" with name change to \"~s\".", [SubpoolName, OldWorkerName, WorkerName]),
            ets:delete(WorkerTbl, OldWorkerName),
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName})
    end,
    
    % Add/Update the record
    ets:insert(WorkerTbl, Worker),
    
    {noreply, State};

handle_cast({remove_worker, WorkerId}, State=#state{subpool=#subpool{name=SubpoolName}, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    case ets:lookup(WorkerLookupTbl, WorkerId) of
        [] -> ok;
        [{_, WorkerName}] ->
            log4erl:info(server, "~s: Deleting worker \"~s\".", [SubpoolName, WorkerName]),
            ets:delete(WorkerLookupTbl, WorkerId),
            ets:delete(WorkerTbl, WorkerName)
    end,
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(check_work_age, State=#state{workq_size=WorkQueueSize}) when WorkQueueSize =< 0 ->
    {noreply, State}; % No dice

handle_info(check_work_age, State) ->
    % Extract state variables
    #state{
        subpool=#subpool{name=SubpoolName, max_cache_size=MaxCacheSize, max_work_age=MaxWorkAge},
        cdaemon=CoinDaemon,
        workq=WorkQueue,
        workq_size=WorkQueueSize
    } = State,
    {NewWorkQueue, NewWorkQueueSize} = check_work_age(SubpoolName, WorkQueue, WorkQueueSize, erlang:now(), MaxWorkAge),
    if
        WorkQueueSize =:= MaxCacheSize, % Cache was max size
        NewWorkQueueSize < MaxCacheSize -> % And now is below max size
            CoinDaemon:post_workunit(); % -> Call for work
        true ->
            ok
    end,
    {noreply, State#state{workq=NewWorkQueue, workq_size=NewWorkQueueSize}};

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{subpool=#subpool{id=undefined}}) ->
    % Here, we crashed at the start having no information at all :/
    log4erl:warn(server, "Subpool terminated."),
    ok;
terminate(_Reason, #state{subpool=#subpool{id=Id, port=Port}, workq=WorkQueue, workq_size=WorkQueueSize, worktbl=WorkTbl, hashtbl=HashTbl, lp_queue=LPQueue}) ->
    % Store work and hashes table
    StorageDir = ecoinpool_util:server_storage_dir(Id),
    ets:tab2file(WorkTbl, binary_to_list(filename:join(StorageDir, "worktbl.ets")), [{extended_info, [object_count]}]),
    ets:tab2file(HashTbl, binary_to_list(filename:join(StorageDir, "hashtbl.ets")), [{extended_info, [object_count]}]),
    % Stop the RPC
    ecoinpool_rpc:stop_rpc(Port),
    % Cancel open connections
    lists:foreach(fun ({_, Req}) -> Req:error({-32603, <<"Server is terminating!">>}) end, LPQueue),
    if
        WorkQueueSize < 0 ->
            lists:foreach(fun ({_, Req, _}) -> Req:error({-32603, <<"Server is terminating!">>}) end, queue:to_list(WorkQueue));
        true ->
            ok
    end,
    % Unregister notifications
    ecoinpool_worker_monitor:set_worker_notifications(Id, []),
    % We don't need to stop the CoinDaemon, because that will be handled by the supervisor
    log4erl:warn(server, "Subpool ~s terminated.", [Id]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

parse_method_and_auth(Req, SubpoolName, WorkerTbl, GetworkMethod, SendworkMethod, AcceptWorkers, LowercaseWorkers, IgnorePasswords) ->
    Action = case Req:get(method) of
        GetworkMethod when GetworkMethod =:= SendworkMethod -> % Distinguish by parameters
            case Req:has_params() of
                true -> sendwork;
                _ -> getwork
            end;
        GetworkMethod ->
            getwork;
        SendworkMethod ->
            sendwork;
        default -> % Getwork is default
            getwork;
        setup_user ->
            setup_user;
        test ->
            test;
        _ ->
            unknown
    end,
    case Action of % First, match for validity
        unknown -> % Bail out
            {error, method_not_found};
        setup_user ->
            case Req:get(params) of
                [UserName] when is_binary(UserName) ->
                    {setup_user, UserName};
                _ ->
                    {error, invalid_method_params}
            end;
        test ->
            case Req:get(auth) of
                unauthorized ->
                    {test, ?TEST_UNAUTH_MESSAGE};
                {MixedCaseUser, Password} ->
                    User = case LowercaseWorkers of
                        true -> binary_to_lower(MixedCaseUser);
                        false -> MixedCaseUser
                    end,
                    case ets:lookup(WorkerTbl, User) of
                        [#worker{pass=Pass}] ->
                            if
                                IgnorePasswords; Pass =:= undefined; Pass =:= Password ->
                                    {test, ?TEST_ACCEPT_MESSAGE};
                                true ->
                                    {test, ?TEST_REJECT_MESSAGE}
                            end;
                        _ ->
                            case AcceptWorkers of
                                any ->
                                    {test, ?TEST_ACCEPT_MESSAGE};
                                valid_address ->
                                    try
                                        btc_protocol:hash160_from_address(User),
                                        {test, ?TEST_ACCEPT_MESSAGE}
                                    catch
                                        error:invalid_bitcoin_address ->
                                            {test, ?TEST_REJECT_ADDRESS_MESSAGE}
                                    end;
                                _ ->
                                    {test, ?TEST_REJECT_MESSAGE}
                            end
                    end
            end;
        _ ->
            % Check authentication
            case Req:get(auth) of
                unauthorized ->
                    log4erl:warn(server, "~s: rpc_request: ~s: Unauthorized!", [SubpoolName, Req:get(ip)]),
                    {error, authorization_required};
                {MixedCaseUser, Password} ->
                    User = case LowercaseWorkers of
                        true -> binary_to_lower(MixedCaseUser);
                        false -> MixedCaseUser
                    end,
                    case ets:lookup(WorkerTbl, User) of
                        [Worker=#worker{pass=Pass}] ->
                            if
                                IgnorePasswords; Pass =:= undefined; Pass =:= Password ->
                                    {ok, Worker, Action};
                                true ->
                                    log4erl:warn(server, "~s: rpc_request: ~s: Wrong password for username ~s!", [SubpoolName, Req:get(ip), User]),
                                    {error, authorization_required}
                            end;
                        _ ->
                            ImplicitWorker = #worker{id=User, name=User},
                            case AcceptWorkers of
                                any ->
                                    {ok, ImplicitWorker, Action};
                                valid_address ->
                                    try
                                        btc_protocol:hash160_from_address(User),
                                        {ok, ImplicitWorker, Action}
                                    catch
                                        error:invalid_bitcoin_address ->
                                            log4erl:warn(server, "~s: rpc_request: ~s: Invalid address ~s!", [SubpoolName, Req:get(ip), User]),
                                            {error, authorization_required}
                                    end;
                                _ ->
                                    log4erl:warn(server, "~s: rpc_request: ~s: Username ~s not found!", [SubpoolName, Req:get(ip), User]),
                                    {error, authorization_required}
                            end
                    end
            end
    end.

assign_work(Req, SubpoolName, Now, MaxWorkAge, MaxCacheSize, RollNTime, Worker=#worker{id=WorkerId, name=WorkerName}, WorkQueue, WorkQueueSize, WorkTbl, CoinDaemon) ->
    % Look if work is available in the Cache
    if
        WorkQueueSize > 0 -> % Cache hit
            {{value, Workunit=#workunit{ts=WorkTS}}, NewWorkQueue} = queue:out(WorkQueue),
            case timer:now_diff(Now, WorkTS) / 1000000 of
                Diff when Diff =< MaxWorkAge -> % Check age
                    case ets:insert_new(WorkTbl, Workunit#workunit{worker_id=WorkerId}) of
                        false -> log4erl:error(server, "~s: assign_work got a collision :/", [SubpoolName]);
                        _ -> ok
                    end,
                    MiningExtensions = Req:get(mining_extensions),
                    Req:ok(CoinDaemon:encode_workunit(Workunit, MiningExtensions), make_response_options(Worker, Workunit, RollNTime, MiningExtensions)),
                    log4erl:info(server, "~s: Cache hit by ~s/~s - Queue size: ~b/~b", [SubpoolName, WorkerName, Req:get(ip), WorkQueueSize-1, MaxCacheSize]),
                    {NewWorkQueue, WorkQueueSize-1};
                _ -> % Try again if too old (tail recursive)
                    log4erl:debug(server, "~s: assign_work: discarded an old workunit.", [SubpoolName]),
                    assign_work(Req, SubpoolName, Now, MaxWorkAge, MaxCacheSize, RollNTime, Worker, NewWorkQueue, WorkQueueSize-1, WorkTbl, CoinDaemon)
            end;
        true -> % Cache miss, append to waiting queue
            log4erl:info(server, "~s: Cache miss by ~s/~s - Queue size: ~b/~b", [SubpoolName, WorkerName, Req:get(ip), WorkQueueSize-1, MaxCacheSize]),
            {queue:in({Worker, Req, normal}, WorkQueue), WorkQueueSize-1}
    end.

check_work(Req, Subpool=#subpool{name=SubpoolName}, Worker=#worker{name=WorkerName}, WorkTbl, HashTbl, CoinDaemon, MMM, ShareTarget) ->
    % Analyze results
    Peer = Req:get(peer),
    case CoinDaemon:analyze_result(Req:get(params)) of
        error ->
            log4erl:warn(server, "~s: Wrong data from ~s/~s: ~p", [SubpoolName, WorkerName, element(1, Peer), Req:get(params)]),
            ecoinpool_share_broker:notify_invalid_share(Subpool, Peer, Worker, data),
            Req:error(invalid_request),
            [];
        Results ->
            % Lookup workunits, check hash target and check duplicates
            ResultsWithWU = lists:map(
                fun ({WorkId, Hash, BData}) ->
                    case ets:lookup(WorkTbl, WorkId) of
                        [Workunit] -> % Found
                            if
                                Hash > ShareTarget ->
                                    {target, Workunit, Hash};
                                true ->
                                    case ets:insert_new(HashTbl, {Hash}) of % Store the new hash or detect as duplicate
                                        true ->
                                            check_for_candidate(SubpoolName, Workunit, Hash, BData, WorkerName, Peer);
                                        _ ->
                                            {duplicate, Workunit, Hash}
                                    end
                            end;
                        _ -> % Not found
                            {stale, Hash}
                    end
                end,
                Results
            ),
            % Process results (this is fast enough)
            process_results(Req, ResultsWithWU, Subpool, Worker, CoinDaemon, MMM),
            % Combine candidate announcements (used by check_new_round)
            lists:foldl(
                fun
                    ({ok, _, _, _, Candidates}, Acc) ->
                        lists:umerge(Candidates, Acc);
                    (_, Acc) ->
                        Acc
                end,
                [],
                ResultsWithWU
            )
    end.

process_results(Req, Results, Subpool=#subpool{name=SubpoolName, rollntime=RollNTime}, Worker=#worker{name=WorkerName}, CoinDaemon, MMM) ->
    % Process all results
    Peer = Req:get(peer),
    {ReplyItems, RejectReason, Candidates} = lists:foldr(
        fun
            ({stale, Hash}, {AccReplyItems, _, AccCandidates}) ->
                ecoinpool_share_broker:notify_invalid_share(Subpool, Peer, Worker, Hash, stale),
                {[invalid | AccReplyItems], "Stale or unknown work", AccCandidates};
            ({duplicate, Workunit, Hash}, {AccReplyItems, _, AccCandidates}) ->
                ecoinpool_share_broker:notify_invalid_share(Subpool, Peer, Worker, Workunit, Hash, duplicate),
                {[invalid | AccReplyItems], "Duplicate work", AccCandidates};
            ({target, Workunit, Hash}, {AccReplyItems, _, AccCandidates}) ->
                ecoinpool_share_broker:notify_invalid_share(Subpool, Peer, Worker, Workunit, Hash, target),
                {[invalid | AccReplyItems], "Hash does not meet share target", AccCandidates};
            ({ok, Workunit, Hash, BData, TheCandidates}, {AccReplyItems, AccRejectReason, AccCandidates}) ->
                ecoinpool_share_broker:notify_share(Subpool, Peer, Worker, Workunit#workunit{data=BData}, Hash, TheCandidates),
                NewCandidates = lists:foldl(
                    fun (Chain, Acc) -> [{Chain, Workunit, Hash, BData} | Acc] end,
                    AccCandidates,
                    TheCandidates
                ),
                {[Hash | AccReplyItems], AccRejectReason, NewCandidates}
        end,
        {[], undefined, []},
        Results 
    ),
    % Send reply
    Options = make_response_options(Worker, RollNTime, Req:get(mining_extensions)),
    case RejectReason of
        undefined ->
            Req:ok(CoinDaemon:make_reply(ReplyItems), Options);
        _ ->
            Req:ok(CoinDaemon:make_reply(ReplyItems), [{reject_reason, RejectReason} | Options])
    end,
    % Send candidates asynchronously, if there are any
    case Candidates of
        [] -> ok;
        _ -> IP = element(1, Peer), spawn(fun () -> send_candidates(Candidates, CoinDaemon, MMM, SubpoolName, WorkerName, IP) end), ok
    end.
    
check_work_age(_, WorkQueue, WorkQueueSize, _, _) when WorkQueueSize =< 0 ->
    {WorkQueue, WorkQueueSize}; % Done

check_work_age(SubpoolName, WorkQueue, WorkQueueSize, Now, MaxWorkAge) ->
    {value, #workunit{ts=WorkTS}} = queue:peek(WorkQueue),
    case timer:now_diff(Now, WorkTS) / 1000000 of
        Diff when Diff > MaxWorkAge ->
            log4erl:debug(server, "~s: check_work_age: discarded an old workunit.", [SubpoolName]),
            check_work_age(SubpoolName, queue:drop(WorkQueue), WorkQueueSize-1, Now, MaxWorkAge); % Check next (tail recursive)
        _ ->
            {WorkQueue, WorkQueueSize} % Done
    end.

make_response_options(#worker{lp=LP}, RollNTime, MiningExtensions) ->
    Options = if
        RollNTime ->
            case lists:member(rollntime, MiningExtensions) of
                true -> [rollntime];
                _ -> []
            end;
        true ->
            []
    end,
    case LP of
        true -> [longpolling | Options];
        _ -> Options
    end.

make_response_options(Worker, #workunit{block_num=BlockNum}, RollNTime, MiningExtensions) ->
    [{block_num, BlockNum} | make_response_options(Worker, RollNTime, MiningExtensions)].

check_new_round(_, []) ->
    ok;
check_new_round(Subpool=#subpool{name=SubpoolName, round=Round}, [main|T]) ->
    case Round of
        undefined ->
            ok;
        _ ->
            log4erl:info(server, "~s: New round: ~b", [SubpoolName, Round+1]),
            ecoinpool_db:set_subpool_round(Subpool, Round+1)
    end,
    check_new_round(Subpool, T);
check_new_round(Subpool=#subpool{aux_pool=#auxpool{name=AuxpoolName, round=Round}}, [aux|T]) ->
    case Round of
        undefined ->
            ok;
        _ ->
            log4erl:info(server, "~s: New round: ~b", [AuxpoolName, Round+1]),
            ecoinpool_db:set_auxpool_round(Subpool, Round+1)
    end,
    check_new_round(Subpool, T);
check_new_round(Subpool, [_|T]) ->
    check_new_round(Subpool, T).

check_aux_pool_config(_, _, undefined, undefined, undefined, _) ->
    undefined;
check_aux_pool_config(_, SubpoolId, _, OldMMM, undefined, _) ->
    % This code will change if multi aux chains are supported
    [AuxDaemonModule] = OldMMM:aux_daemon_modules(),
    ecoinpool_server_sup:remove_auxdaemon(SubpoolId, AuxDaemonModule, OldMMM);
check_aux_pool_config(SubpoolName, SubpoolId, OldAuxpool, OldMMM, Auxpool, StartCoinDaemon) ->
    % This code will change if multi aux chains are supported
    #auxpool{pool_type=PoolType, aux_daemon_config=AuxDaemonConfig} = Auxpool,
    OldAuxDaemonConfig = case OldAuxpool of
        undefined ->
            undefined;
        _ when StartCoinDaemon ->
            undefined; % Force restart if the CoinDaemon was restarted
        #auxpool{aux_daemon_config=OADC} ->
            OADC
    end,
    % Derive the AuxDaemon module name from PoolType + "_auxdaemon"
    AuxDaemonModule = list_to_atom(lists:concat([PoolType, "_auxdaemon"])),
    
    OldAuxDaemonModule = case OldMMM of
        undefined -> undefined;
        _ -> [M] = OldMMM:aux_daemon_modules(), M
    end,
    StartAuxDaemon = if
        OldAuxDaemonModule =:= AuxDaemonModule, OldAuxDaemonConfig =:= AuxDaemonConfig -> false;
        OldAuxDaemonModule =:= undefined -> true;
        true -> ecoinpool_server_sup:remove_auxdaemon(SubpoolId, OldAuxDaemonModule, OldMMM), true
    end,
    if
        StartAuxDaemon ->
            case ecoinpool_server_sup:add_auxdaemon(SubpoolId, AuxDaemonModule, [{pool_type, PoolType} | AuxDaemonConfig], undefined) of
                {ok, NewMMM} -> NewMMM;
                _Error -> log4erl:warn(server, "~s: Could not start AuxDaemon!", [SubpoolName]), undefined
            end;
        true ->
            OldMMM
    end.

check_for_candidate(SubpoolName, Workunit=#workunit{aux_work=AuxWork, aux_work_stale=AuxWorkStale}, Hash, BData, WorkerName, Peer) ->
    MainCandidate = case hash_is_below_target(Hash, Workunit) of
        true -> log4erl:warn(server, "~s: +++ Main candidate share from ~s/~s! +++", [SubpoolName, WorkerName, element(1, Peer)]), [main];
        _ -> []
    end,
    AuxCandidate = if
        AuxWorkStale ->
            [];
        true ->
            case hash_is_below_target(Hash, AuxWork) of
                true -> log4erl:warn(server, "~s: +++ Aux candidate share from ~s/~s! +++", [SubpoolName, WorkerName, element(1, Peer)]), [aux];
                _ -> []
            end
    end,
    {ok, Workunit, Hash, BData, lists:merge(MainCandidate, AuxCandidate)}.

hash_is_below_target(_, undefined) ->
    false;
hash_is_below_target(Hash, #workunit{target=Target}) ->
    Hash =< Target;
hash_is_below_target(Hash, #auxwork{target=Target}) ->
    Hash =< Target.

send_candidates(Candidates, CoinDaemon, MMM, SubpoolName, WorkerName, IP) ->
    lists:foreach(
        fun (C={Chain, _, _, _}) ->
            case send_candidate(C, CoinDaemon, MMM) of
                accepted ->
                    log4erl:warn(server, "~s: Data sent upstream from ~s/~s to ~p chain got accepted!", [SubpoolName, WorkerName, IP, Chain]);
                rejected ->
                    log4erl:warn(server, "~s: Data sent upstream from ~s/~s to ~p chain got rejected!", [SubpoolName, WorkerName, IP, Chain]);
                {error, Message} ->
                    log4erl:error(server, "~s: Upstream error from ~s/~s to ~p chain! Message: ~p", [SubpoolName, WorkerName, IP, Chain, Message])
            end
        end,
        Candidates
    ).

send_candidate({main, _, _, BData}, CoinDaemon, _) ->
    CoinDaemon:send_result(BData);
send_candidate({aux, _, _, _}, _, undefined) ->
    {error, <<"Merged mining manager is missing!">>};
send_candidate({aux, Workunit=#workunit{aux_work=AuxWork}, Hash, BData}, CoinDaemon, MMM) ->
    case CoinDaemon:get_first_tx_with_branches(Workunit) of
        {ok, FirstTransaction, MerkleTreeBranches} ->
            MMM:send_aux_pow(AuxWork, FirstTransaction, Hash, MerkleTreeBranches, BData);
        Error ->
            Error
    end.

mark_aux_work_stale(_, '$end_of_table') ->
    ok;
mark_aux_work_stale(WorkTbl, Key) ->
    ets:update_element(WorkTbl, Key, {#workunit.aux_work_stale, true}),
    mark_aux_work_stale(WorkTbl, ets:next(WorkTbl, Key)).

binary_to_lower(B) ->
    list_to_binary(string:to_lower(binary_to_list(B))).

json_add_value(Key, Value, {ObjProps}) ->
    {[{Key, Value} | ObjProps]}.
