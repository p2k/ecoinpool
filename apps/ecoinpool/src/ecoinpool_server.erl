
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

-include("ecoinpool_db_records.hrl").
-include("ecoinpool_workunit.hrl").

-export([start_link/1, reload_config/1, update_worker/2, remove_worker/2, get_worker_notifications/1, store_workunit/2, new_block_detected/1]).

% Callbacks from ecoinpool_rpc
-export([rpc_request/6, rpc_lp_request/4]).

% Callbacks from gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

% Internal state record
-record(state, {
    subpool,
    cdaemon_mod,
    cdaemon_pid,
    gw_method,
    sw_method,
    worktbl,
    workertbl,
    workerltbl
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(SubpoolId) ->
    gen_server:start_link({global, {subpool, SubpoolId}}, ?MODULE, [SubpoolId], []).

reload_config(Subpool=#subpool{id=Id}) ->
    gen_server:cast({global, {subpool, Id}}, {reload_config, Subpool}).

rpc_request(PID, Peer, Method, Params, Auth, Responder) ->
    gen_server:cast(PID, {rpc_request, Peer, Method, Params, Auth, Responder}).

rpc_lp_request(PID, Peer, Auth, Responder) ->
    gen_server:cast(PID, {rpc_lp_request, Peer, Auth, Responder}).

update_worker(SubpoolId, Worker) ->
    gen_server:cast({global, {subpool, SubpoolId}}, {update_worker, Worker}).

remove_worker(SubpoolId, WorkerId) ->
    gen_server:cast({global, {subpool, SubpoolId}}, {remove_worker, WorkerId}).

% Returns a list of sub-pools for which notifications should be sent
% For simple configurations, this just returns the SubpoolId again, but for
% multi-pool-configurations this may return a longer list
get_worker_notifications(SubpoolId) ->
    gen_server:call({global, {subpool, SubpoolId}}, get_worker_notifications).

store_workunit(SubpoolId, Workunit) ->
    gen_server:cast({global, {subpool, SubpoolId}}, {store_workunit, Workunit}).

new_block_detected(SubpoolId) ->
    gen_server:cast({global, {subpool, SubpoolId}}, new_block_detected).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init([SubpoolId]) ->
    io:format("Subpool ~p starting...~n", [SubpoolId]),
    % Trap exit
    process_flag(trap_exit, true),
    % Setup the work table and worker table
    WorkTbl = ets:new(worktbl, [set, protected, {keypos, 2}]),
    WorkerTbl = ets:new(workertbl, [set, protected, {keypos, 5}]),
    WorkerLookupTbl = ets:new(workerltbl, [set, protected]),
    % Get Subpool record; terminate on error
    {ok, Subpool} = ecoinpool_db:get_subpool_record(SubpoolId),
    % Schedule config reload
    gen_server:cast(self(), {reload_config, Subpool}),
    % Schedule workers reload (TODO: move this to reload_config if worker configuration changed)
    gen_server:cast(self(), reload_workers),
    {ok, #state{subpool=#subpool{}, worktbl=WorkTbl, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}}.

handle_call(get_worker_notifications, _From, State=#state{subpool=Subpool}) ->
    % Returns the sub-pool IDs for which worker changes should be retrieved
    % Note: Currently only returns the own sub-pool ID
    #subpool{id=SubpoolId} = Subpool,
    {reply, [SubpoolId], State};

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({reload_config, Subpool}, State=#state{subpool=OldSubpool, cdaemon_mod=OldCoinDaemonModule, cdaemon_pid=OldCoinDaemon}) ->
    % Extract config
    #subpool{id=SubpoolId, port=Port, pool_type=PoolType, coin_daemon_config=CoinDaemonConfig} = Subpool,
    #subpool{port=OldPort, coin_daemon_config=OldCoinDaemonConfig} = OldSubpool,
    % Derive the CoinDaemon module name from PoolType + "_coindaemon"
    CoinDaemonModule = list_to_atom(lists:concat([PoolType, "_coindaemon"])),
    
    % Setup the shares database
    ok = ecoinpool_db:setup_shares_db(Subpool),
    
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
    StartCoinDaemon = if
        OldCoinDaemonModule =:= CoinDaemonModule, OldCoinDaemonConfig =:= CoinDaemonConfig -> false;
        OldCoinDaemonModule =:= undefined -> true;
        true -> ecoinpool_server_sup:stop_coindaemon(SubpoolId), true
    end,
    {ok, CoinDaemon} = if
        StartCoinDaemon ->
            case ecoinpool_server_sup:start_coindaemon(SubpoolId, CoinDaemonModule, CoinDaemonConfig) of
                {ok, Pid, _} -> {ok, Pid};
                {ok, Pid} -> {ok, Pid};
                Error -> ecoinpool_rpc:stop_rpc(Port), Error % Fail but close the RPC beforehand
            end;
        true -> {ok, OldCoinDaemon}
    end,
    GetworkMethod = CoinDaemonModule:getwork_method(),
    SendworkMethod = CoinDaemonModule:sendwork_method(),
    
    {noreply, State#state{subpool=Subpool, cdaemon_mod=CoinDaemonModule, cdaemon_pid=CoinDaemon, gw_method=GetworkMethod, sw_method=SendworkMethod}};

handle_cast(reload_workers, State=#state{subpool=#subpool{id=SubpoolId}, workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    ets:delete_all_objects(WorkerLookupTbl),
    ets:delete_all_objects(WorkerTbl),
    
    % Note: Currently only retrieves the own sub-pool workers
    lists:foreach(
        fun (Worker=#worker{id=WorkerId, name=WorkerName}) ->
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName}),
            ets:insert(WorkerTbl, Worker)
        end,
        ecoinpool_db:get_workers_for_subpools([SubpoolId])
    ),
    
    % Register for worker change notifications
    % Note: Currently only sets the own sub-pool ID
    ecoinpool_worker_monitor:set_worker_notifications(SubpoolId, [SubpoolId]),
    
    {noreply, State};

handle_cast({rpc_request, Peer, Method, Params, Auth, Responder}, State) ->
    % Extract state variables
    #state{subpool=Subpool, cdaemon_mod=CoinDaemonModule, cdaemon_pid=CoinDaemon, gw_method=GetworkMethod, sw_method=SendworkMethod, workertbl=WorkerTbl, worktbl=WorkTbl} = State,
    % Check the method
    Action = case Method of
        GetworkMethod when GetworkMethod =:= SendworkMethod -> % Distinguish by parameters
            if
                length(Params) =:= 0 -> getwork;
                true -> sendwork
            end;
        GetworkMethod ->
            getwork;
        SendworkMethod ->
            sendwork;
        default -> % Getwork is default
            getwork;
        _ ->
            unknown
    end,
    case Action of % First, match for validity
        unknown -> % Bail out
            Responder({error, method_not_found});
        _ ->
            % Check authentication
            case Auth of
                unauthorized ->
                    io:format("rpc_request: ~s: Unauthorized!~n", [Peer]),
                    Responder({error, authorization_required});
                {User, Password} ->
                    case ets:lookup(WorkerTbl, User) of
                        [Worker=#worker{pass=Pass}] when Pass =:= null; Pass =:= Password ->
                            case Action of % Now match for the action
                                getwork ->
                                    case assign_work(Worker, WorkTbl, CoinDaemonModule, CoinDaemon, Responder) of
                                        hit -> io:format("Cache hit by ~s/~s!~n", [User, Peer]);
                                        miss -> io:format("Cache miss by ~s/~s!~n", [User, Peer])
                                    end;
                                sendwork ->
                                    check_work(User, Peer, Params, Subpool, Worker, WorkTbl, CoinDaemonModule, CoinDaemon, Responder)
                            end;
                        [] ->
                            io:format("rpc_request: ~s: Wrong password for username ~p!~n", [Peer, User]),
                            Responder({error, authorization_required})
                    end
            end
    end,
    {noreply, State};

handle_cast({rpc_lp_request, _Peer, _Auth, Responder}, State=#state{}) ->
    %TODO
    Responder({error, {-1, <<"not implemented">>}}),
    {noreply, State};

handle_cast(new_block_detected, State=#state{worktbl=WorkTbl}) ->
    io:format("New block! Removing ~b workunits.~n", [ets:info(WorkTbl, size)]),
    ets:delete_all_objects(WorkTbl), % Clear the work table
    %TODO longpolling
    {noreply, State};

handle_cast({store_workunit, Workunit}, State=#state{worktbl=WorkTbl}) ->
    ets:insert(WorkTbl, Workunit),
    {noreply, State};

handle_cast({update_worker, Worker=#worker{id=WorkerId, name=WorkerName}}, State=#state{workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    ets:match(WorkerTbl, #worker{id=WorkerId, _='_'}),
    
    % Check if existing
    case ets:lookup(WorkerLookupTbl, WorkerId) of
        [] -> % Brand new
            io:format("Brand new: ~p~n", [Worker]),
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName});
        [{_, WorkerName}] -> % Existing and worker name matches
            io:format("Existing and matches: ~p~n", [WorkerId]),
            ok;
        [{_, OldWorkerName}] -> % Existing & name change
            io:format("Name change: ~p - ~p -> ~p~n", [WorkerId, OldWorkerName, WorkerName]),
            ets:delete(WorkerTbl, OldWorkerName),
            ets:insert(WorkerLookupTbl, {WorkerId, WorkerName})
    end,
    
    % Add/Update the record
    ets:insert(WorkerTbl, Worker),
    
    {noreply, State};

handle_cast({remove_worker, WorkerId}, State=#state{workertbl=WorkerTbl, workerltbl=WorkerLookupTbl}) ->
    case ets:lookup(WorkerLookupTbl, WorkerId) of
        [] -> ok;
        [{_, WorkerName}] ->
            ets:delete(WorkerLookupTbl, WorkerId),
            ets:delete(WorkerTbl, WorkerName)
    end,
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{subpool=#subpool{id=Id, port=Port}}) ->
    % Stop the RPC
    ecoinpool_rpc:stop_rpc(Port),
    % Unregister notifications
    ecoinpool_worker_monitor:set_worker_notifications(Id, []),
    % We don't need to stop the CoinDaemon, because that will be handled by the supervisor
    io:format("Subpool ~p terminated.~n", [Id]),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Other functions
%% ===================================================================

assign_work(#worker{id=WorkerId}, WorkTbl, CoinDaemonModule, CoinDaemon, Responder) ->
    % Query the cache
    case ets:match_object(WorkTbl, #workunit{worker_id=undefined, _='_'}, 1) of
        {[Workunit], _Cont} -> % Cache hit
            ets:insert(WorkTbl, Workunit#workunit{worker_id=WorkerId}),
            Responder({ok, CoinDaemonModule:encode_workunit(Workunit)}),
            hit;
        _ -> % Cache miss
            % Spawn a process to get work
            ServerPID = self(),
            spawn(
                fun () ->
                    Responder(case CoinDaemonModule:get_workunit(CoinDaemon) of
                        {error, Message} ->
                            {error, {-1, Message}};
                        {Success, Workunit} ->
                            case Success of
                                newblock ->
                                    gen_server:cast(ServerPID, new_block_detected);
                                _ ->
                                    ok
                            end,
                            gen_server:cast(ServerPID, {store_workunit, Workunit#workunit{worker_id=WorkerId}}),
                            {ok, CoinDaemonModule:encode_workunit(Workunit)}
                    end)
                end
            ),
            miss
    end.

check_work(User, Peer, Params, Subpool, Worker, WorkTbl, CoinDaemonModule, CoinDaemon, Responder) ->
    % Analyze result
    case CoinDaemonModule:analyze_result(Params) of
        {WorkId, Hash, BData} ->
            % Lookup workunit
            case ets:lookup(WorkTbl, WorkId) of
                [Workunit] -> % Found
                    ShareTarget = CoinDaemonModule:share_target(),
                    if % Validate
                        Hash < ShareTarget ->
                            % Submit share to database and also to the daemon if it isn't a duplicate and meets the work target
                            spawn(
                                fun () ->
                                    Responder(case ecoinpool_db:store_share(Subpool, Peer, Worker, Workunit#workunit{data=BData}, Hash) of
                                        duplicate ->
                                            io:format("Duplicate work from ~s/~s!~n", [User, Peer]),
                                            {ok, CoinDaemonModule:rejected_reply(), [{reject_reason, "Duplicate work"}]};
                                        candidate -> % We got a winner (?)
                                            case CoinDaemonModule:send_result(CoinDaemon, BData) of
                                                {accepted, Reply} ->
                                                    io:format("Data sent upstream from ~s/~s got accepted!~n", [User, Peer]),
                                                    {ok, Reply};
                                                {rejected, Reply} ->
                                                    io:format("Data sent upstream from ~s/~s got rejected!~n", [User, Peer]),
                                                    {ok, Reply, [{reject_reason, "Rejected by coin daemon"}]};
                                                {error, Message} ->
                                                    io:format("Upstream error from ~s/~s! Message: ~p~n", [User, Peer, Message]),
                                                    {error, {-1, Message}}
                                            end;
                                        valid -> % consolation prize
                                            io:format("Got valid share from ~s/~s.~n", [User, Peer]),
                                            {ok, CoinDaemonModule:normal_reply(Hash)}
                                    end)
                                end
                            );
                        true ->
                            io:format("Invalid hash from ~s/~s!~n", [User, Peer]),
                            ecoinpool_db:store_invalid_share(Subpool, Peer, Worker, Workunit, Hash, target),
                            Responder({ok, CoinDaemonModule:rejected_reply(), [{reject_reason, "Hash does not meet share target"}]})
                    end;
                _ -> % Not found
                    io:format("Stale share from ~s/~s!~n", [User, Peer]),
                    ecoinpool_db:store_invalid_share(Subpool, Peer, Worker, stale),
                    Responder({ok, CoinDaemonModule:rejected_reply(), [{reject_reason, "Stale or unknown work"}]})
            end;
        _ ->
            io:format("Wrong data from ~s/~s!~n~p~n", [User, Peer, Params]),
            ecoinpool_db:store_invalid_share(Subpool, Peer, Worker, data),
            Responder({error, invalid_request})
    end.
