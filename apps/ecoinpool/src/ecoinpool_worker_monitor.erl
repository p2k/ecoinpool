
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

-module(ecoinpool_worker_monitor).
-behaviour(gen_changes).

-include("ecoinpool_db_records.hrl").

-export([start_link/1, set_worker_notifications/2]).

-export([init/1, handle_change/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

% Internal state record
-record(state, {
    notify_map,
    all_subpools
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ConfDb) ->
    % This module only monitors new changes, so get the current sequence number
    {ok, DbInfo} = couchbeam:db_info(ConfDb),
    Seq = couchbeam_doc:get_value(<<"update_seq">>, DbInfo),
    case gen_changes:start_link(?MODULE, ConfDb, [continuous, heartbeat, {filter, "doctypes/workers_only"}, {since, Seq}], []) of
        {ok, PID} ->
            true = register(?MODULE, PID),
            {ok, PID};
        Other ->
            Other
    end.

set_worker_notifications(SubpoolId, NotifyForSubpoolIds) ->
    gen_changes:cast(?MODULE, {set_worker_notifications, SubpoolId, NotifyForSubpoolIds}).

%% ===================================================================
%% Gen_Changes callbacks
%% ===================================================================

init([]) ->
    % Get already running subpools; useful if we were restarted
    case ecoinpool_sup:running_subpools() of
        [] ->
            {ok, #state{notify_map=dict:new(), all_subpools=sets:new()}};
        ActiveSubpoolIds ->
            gen_changes:cast(self(), query_all_subpools),
            {ok, #state{all_subpools=sets:from_list(ActiveSubpoolIds)}}
    end.

handle_change({ChangeProps}, State) ->
    WorkerId = proplists:get_value(<<"id">>, ChangeProps),
    case proplists:get_value(<<"_deleted">>, ChangeProps) of
        true ->
            gen_changes:cast(self(), {broadcast_remove_worker, WorkerId});
        _ ->
            gen_changes:cast(self(), {broadcast_update_worker, WorkerId})
    end,
    {noreply, State}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(query_all_subpools, State=#state{all_subpools=AllSubpoolIds}) ->
    % Only called on a fresh start; (re-)creates the notification map
    % Note: The notification map maps worker sub-pool IDs to a set of sub-pools
    %       which are interested in those workers.
    NotifyMap = sets:fold(
        fun (SubpoolId, AccNotifyMap) ->
            lists:foldl(
                fun (SourceSubpoolId, AccAccNotifyMap) ->
                    NotifySet = case dict:find(SourceSubpoolId, AccAccNotifyMap) of
                        {ok, OldNotifySet} -> sets:add_element(SubpoolId, OldNotifySet);
                        _ -> sets:from_list([SubpoolId])
                    end,
                    dict:store(SourceSubpoolId, NotifySet, AccAccNotifyMap)
                end,
                AccNotifyMap,
                ecoinpool_server:get_worker_notifications(SubpoolId)
            )
        end,
        dict:new(),
        AllSubpoolIds
    ),
    {noreply, State#state{notify_map=NotifyMap}};

handle_cast({set_worker_notifications, SubpoolId, NotifyForSubpoolIds}, State=#state{all_subpools=AllSubpoolIds, notify_map=OldNotifyMap}) ->
    % First update existing
    NotifyMapTmp1 = dict:map(
        fun (SourceSubpoolId, NotifySet) ->
            case lists:member(SourceSubpoolId, NotifyForSubpoolIds) of
                true -> % The sub-pool is interested in workers for this source sub-pool
                    sets:add_element(SubpoolId, NotifySet);
                _ -> % The sub-pool is not interested
                    sets:del_element(SubpoolId, NotifySet)
            end
        end,
        OldNotifyMap
    ),
    % Second remove empty
    NotifyMapTmp2 = dict:filter(fun (_, NotifySet) -> sets:size(NotifySet) > 0 end, NotifyMapTmp1),
    % Last add missing sources
    NotifyMap = lists:foldl(
        fun (SourceSubpoolId, AccNotifyMap) ->
            dict:store(SourceSubpoolId, sets:from_list([SubpoolId]), AccNotifyMap)
        end,
        NotifyMapTmp2,
        NotifyForSubpoolIds -- dict:fetch_keys(NotifyMapTmp2)
    ),
    if
        length(NotifyForSubpoolIds) =:= 0 ->
            {noreply, State#state{all_subpools=sets:del_element(SubpoolId, AllSubpoolIds), notify_map=NotifyMap}};
        true ->
            {noreply, State#state{all_subpools=sets:add_element(SubpoolId, AllSubpoolIds), notify_map=NotifyMap}}
    end;

handle_cast({broadcast_remove_worker, WorkerId}, State=#state{all_subpools=AllSubpoolIds}) ->
    lists:foreach(
        fun (SubpoolId) -> ecoinpool_server:remove_worker(SubpoolId, WorkerId) end,
        sets:to_list(AllSubpoolIds)
    ),
    {noreply, State};

handle_cast({broadcast_update_worker, WorkerId}, State=#state{notify_map=NotifyMap}) ->
    % Load the worker record
    case ecoinpool_db:get_worker_record(WorkerId) of
        {ok, Worker=#worker{sub_pool_id=SubpoolId}} ->
            % Query the notification map where to send this worker to
            case dict:find(SubpoolId, NotifyMap) of
                {ok, NotifySet} ->
                    sets:fold(
                        fun (TargetSubpoolId, _) -> io:format("!!!~n"), ecoinpool_server:update_worker(TargetSubpoolId, Worker) end,
                        ok,
                        NotifySet
                    );
                _ ->
                    ok
            end;
        {error, missing} -> % Ignore missing workers (shouldn't happen anyway)
            io:format("ecoinpool_worker_monitor:broadcast_update_worker: Missing document for worker ID: ~p.", [WorkerId]);
        {error, invalid} -> % Ignore invalid workers
            io:format("ecoinpool_worker_monitor:broadcast_update_worker: Invalid document for worker ID: ~p.", [WorkerId])
    end,
    {noreply, State};

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
