
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

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

-export([start_link/1]).

-export([init/1, handle_change/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    active_subpools,
    current_subpools,
    subpool_records
}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ConfDb) ->
    gen_changes:start_link(?MODULE, ConfDb, [continuous, heartbeat, include_docs, {filter, "doctypes/pool_only"}], []).

%% ===================================================================
%% Gen_Changes callbacks
%% ===================================================================

init([]) ->
    % Get already running subpools; useful if we were restarted
    ActiveSubpools = sets:from_list(ecoinpool_sup:running_subpools()),
    {ok, #state{active_subpools=ActiveSubpools, current_subpools=sets:new(), subpool_records=dict:new()}}.

handle_change({ChangeProps}, State) ->
    case proplists:get_value(<<"id">>, ChangeProps) of
        <<"configuration">> ->
            gen_changes:cast(self(), {reload_root_config, proplists:get_value(<<"doc">>, ChangeProps)});
        OtherId ->
            case proplists:get_value(<<"deleted">>, ChangeProps) of
                true ->
                    gen_changes:cast(self(), {remove_subpool, OtherId, true});
                _ ->
                    gen_changes:cast(self(), {reload_subpool, proplists:get_value(<<"doc">>, ChangeProps)})
            end
    end,
    {noreply, State}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast({reload_root_config, Doc}, State=#state{active_subpools=ActiveSubpools, subpool_records=SubpoolRecords}) ->
    {ok, #configuration{active_subpools=CurrentSubpoolIds, view_update_interval=ViewUpdateInterval}} = ecoinpool_db:parse_configuration_document(Doc),
    
    ecoinpool_db:set_view_update_interval(ViewUpdateInterval),
    
    ActiveSubpoolIds = sets:to_list(ActiveSubpools),
    
    lists:foreach( % Add new sub-pools
        fun (SubpoolId) ->
            case dict:find(SubpoolId, SubpoolRecords) of
                {ok, Subpool} ->
                    gen_changes:cast(self(), {reload_subpool, Subpool});
                _ ->
                    ok % If we don't have the subpool record now, it has to follow later in the changes stream
            end
        end,
        CurrentSubpoolIds -- ActiveSubpoolIds
    ),
    lists:foreach( % Remove deleted sub-pools
        fun (SubpoolId) ->
            gen_changes:cast(self(), {remove_subpool, SubpoolId, false})
        end,
        ActiveSubpoolIds -- CurrentSubpoolIds
    ),
    
    {noreply, State#state{current_subpools=sets:from_list(CurrentSubpoolIds)}};

handle_cast({reload_subpool, Doc={_}}, State=#state{subpool_records=SubpoolRecords}) ->
    case ecoinpool_db:parse_subpool_document(Doc) of
        {ok, Subpool=#subpool{id=SubpoolId}} ->
            % Store sub-pool and check if it has to be activated/reloaded
            handle_cast({reload_subpool, Subpool}, State#state{subpool_records=dict:store(SubpoolId, Subpool, SubpoolRecords)});
        {error, invalid} ->
            log4erl:warn("ecoinpool_cfg_monitor: reload_subpool: Ignoring an invalid subpool document."),
            {noreply, State}
    end;

handle_cast({reload_subpool, Subpool=#subpool{id=SubpoolId}}, State=#state{active_subpools=ActiveSubpools, current_subpools=CurrentSubpools}) ->
    % Check if sub-pool is already active
    case sets:is_element(SubpoolId, ActiveSubpools) of
        true -> % Yes: Reload the sub-pool, leave others as they are
            ecoinpool_sup:reload_subpool(Subpool),
            {noreply, State};
        _ -> % No: Add new sub-pool, if we should
            case sets:is_element(SubpoolId, CurrentSubpools) of
                true ->
                    ecoinpool_sup:start_subpool(SubpoolId),
                    {noreply, State#state{active_subpools=sets:add_element(SubpoolId, ActiveSubpools)}};
                _ ->
                    {noreply, State}
            end
    end;

handle_cast({remove_subpool, SubpoolId, DeleteRecord}, State=#state{active_subpools=ActiveSubpools, subpool_records=SubpoolRecords}) ->
    State1 = if
        DeleteRecord ->
            State#state{subpool_records=dict:erase(SubpoolId, SubpoolRecords)};
        true ->
            State
    end,
    case sets:is_element(SubpoolId, ActiveSubpools) of
        true ->
            ecoinpool_sup:stop_subpool(SubpoolId),
            {noreply, State1#state{active_subpools=sets:del_element(SubpoolId, ActiveSubpools)}};
        _ ->
            {noreply, State1}
    end;

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.
