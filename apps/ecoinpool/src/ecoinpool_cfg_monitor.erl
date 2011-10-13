
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
    subpools
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
    {ok, #state{subpools=dict:new()}}.

handle_change({ChangeProps}, State=#state{subpools=CurrentSubPools}) ->
    case proplists:get_value(<<"id">>, ChangeProps) of
        <<"configuration">> -> % The one and only root config document
            gen_changes:cast(self(), reload_root_config); % Schedule root config reload
        OtherId ->
            case dict:is_key(OtherId, CurrentSubPools) of
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
    
    CurrentSubPoolIds = dict:fetch_keys(CurrentSubPools),
    
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
            % Check if sub-pool is already there
            case dict:find(SubPoolId, CurrentSubPools) of
                {ok, OldSubpool} -> % Yes: Reconfigure the sub-pool, leave others as they are
                    reconfigure_subpool(OldSubpool, Subpool);
                error -> % No: Add new sub-pool
                    start_subpool(Subpool)
            end,
            % Add/Update data
            {noreply, State#state{subpools=dict:store(SubPoolId, Subpool, CurrentSubPools)}};
        
        {error, missing} -> % Stop if missing
            case dict:find(SubPoolId, CurrentSubPools) of
                {ok, OldSubpool} ->
                    stop_subpool(OldSubpool),
                    {noreply, State#state{subpools=dict:erase(SubPoolId, CurrentSubPools)}};
                error ->
                    {noreply, State}
            end;
        
        {error, invalid} -> % Ignore on invalid
            io:format("ecoinpool_cfg_monitor:reload_subpool: Invalid document for subpool ID: ~p.", [SubPoolId]),
            {noreply, State}
    end;

handle_cast({remove_subpool, SubPoolId}, State=#state{subpools=CurrentSubPools}) ->
    case dict:find(SubPoolId, CurrentSubPools) of
        {ok, Subpool} ->
            stop_subpool(Subpool),
            {noreply, State#state{subpools=dict:erase(SubPoolId, CurrentSubPools)}};
        error ->
            {noreply, State}
    end;

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
