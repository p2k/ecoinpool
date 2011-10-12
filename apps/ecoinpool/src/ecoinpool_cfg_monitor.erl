
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

-module(ecoinpool_cfg_monitor).
-behaviour(gen_changes).

-include("ecoinpool_db_records.hrl").

-export([start_link/1]).

-export([init/1, handle_change/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

% Internal state record
-record(state, {
    subpools=[]
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ConfDb) ->
    gen_changes:start_link(?MODULE, ConfDb, [continuous, heartbeat, {filter, "doctypes/pool_only"}], []).

%% ===================================================================
%% Gen_Changes callbacks
%% ===================================================================

init([]) ->
    {ok, #state{}}.

handle_change({ChangeProps}, State=#state{subpools=CurrentSubPools}) ->
    case proplists:get_value(<<"id">>, ChangeProps) of
        <<"configuration">> -> % The one and only root config document
            gen_changes:cast(self(), reload_root_config); % Schedule root config reload
        OtherId ->
            case lists:any(fun (#subpool{id=SubPoolId}) -> SubPoolId =:= OtherId end, CurrentSubPools) of
                true ->
                    gen_changes:cast(self(), {reload_subpool, OtherId});
                _ ->
                    io:format("ecoinpool_cfg_monitor:handle_change: Unhandled change: ~p~n", [OtherId])
            end
    end,
    {noreply, State}.

handle_call(_Message, _From, State=#state{}) ->
    {reply, error, State}.

handle_cast(reload_root_config, State=#state{subpools=CurrentSubPools}) ->
    % Load the root configuration, crash on error
    {ok, #configuration{active_subpools=ActiveSubPoolIds}} = ecoinpool_db:get_configuration(),
    
    CurrentSubPoolIds = lists:map(fun (#subpool{id=SubPoolId}) -> SubPoolId end, CurrentSubPools),
    
    lists:foreach( % Add new sub-pools
        fun (SubPoolId) ->
            gen_changes:cast(self(), {reload_subpool, SubPoolId})
        end,
        ActiveSubPoolIds -- CurrentSubPoolIds
    ),
    lists:foreach( % Remove deleted sub-pools
        fun (SubPoolId) ->
            gen_changes:cast(self(), {remove_subpool, SubPoolId})
        end,
        CurrentSubPoolIds -- ActiveSubPoolIds
    ),
    
    {noreply, State};

handle_cast({reload_subpool, SubPoolId}, State=#state{subpools=CurrentSubPools}) ->
    % Load the sub-pool configuration
    case ecoinpool_db:get_subpool_record(SubPoolId) of
        {ok, Subpool} ->
            CurrentSubPoolIds = lists:map(fun (#subpool{id=Id}) -> Id end, CurrentSubPools),
            
            % Check if sub-pool is already there
            case lists:member(SubPoolId, CurrentSubPoolIds) of
                true -> % Yes: Reconfigure the sub-pool, leave others as they are
                    NewCurrentSubPools = lists:map(
                        fun (OldSubpool=#subpool{id=Id}) ->
                            if
                                Id =:= SubPoolId ->
                                    reconfigure_subpool(OldSubpool, Subpool),
                                    Subpool;
                                true ->
                                    OldSubpool
                            end
                        end,
                        CurrentSubPools
                    ),
                    {noreply, State#state{subpools=NewCurrentSubPools}};
                _ -> % No: Add new sub-pool
                    start_subpool(Subpool),
                    {noreply, State#state{subpools=[Subpool|CurrentSubPools]}}
            end;
        
        {error, missing} -> % Stop if missing
            NewCurrentSubPools = lists:filter(
                fun (OldSubpool=#subpool{id=Id}) ->
                    if
                        Id =:= SubPoolId ->
                            stop_subpool(OldSubpool),
                            false;
                        true ->
                            true
                    end
                end,
                CurrentSubPools
            ),
            {noreply, State#state{subpools=NewCurrentSubPools}};
        
        {error, invalid} -> % Ignore on invalid
            io:format("ecoinpool_cfg_monitor:reload_subpool: Invalid document for subpool ID: ~p.", [SubPoolId]),
            {noreply, State}
    end;

handle_cast({remove_subpool, SubPoolId}, State=#state{subpools=CurrentSubPools}) ->
    NewCurrentSubPools = lists:filter(
        fun (Subpool=#subpool{id=Id}) ->
            if
                Id =:= SubPoolId ->
                    stop_subpool(Subpool),
                    false;
                true ->
                    true
            end
        end,
        CurrentSubPools
    ),
    {noreply, State#state{subpools=NewCurrentSubPools}};

handle_cast(_Message, State=#state{}) ->
    io:format("ecoinpool_cfg_monitor:handle_cast: Unhandled message: ~p~n", [_Message]),
    {noreply, State}.

handle_info(_Message, State=#state{}) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Private functions
%% ===================================================================

start_subpool(Subpool=#subpool{}) ->
    io:format("start_subpool ~p~n", [Subpool]),
    ok.

stop_subpool(Subpool=#subpool{}) ->
    io:format("stop_subpool ~p~n", [Subpool]),
    ok.

reconfigure_subpool(_OldSubpool=#subpool{}, Subpool=#subpool{}) ->
    %TODO
    io:format("reconfigure_subpool ~p~n", [Subpool]),
    ok.
