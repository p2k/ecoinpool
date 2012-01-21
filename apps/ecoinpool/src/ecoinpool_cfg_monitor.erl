
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
    subpool_records,
    share_loggers = []
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
    NewState = case proplists:get_value(<<"id">>, ChangeProps) of
        <<"configuration">> ->
            reload_root_config(proplists:get_value(<<"doc">>, ChangeProps), State);
        OtherId ->
            case proplists:get_value(<<"deleted">>, ChangeProps) of
                true ->
                    remove_subpool(OtherId, true, State);
                _ ->
                    reload_subpool(proplists:get_value(<<"doc">>, ChangeProps), State)
            end
    end,
    {noreply, NewState}.

handle_call(_Message, _From, State) ->
    {reply, error, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%% ===================================================================
%% Other functions
%% ===================================================================

-spec reload_root_config(Doc :: {[]}, State :: #state{}) -> #state{}.
reload_root_config(Doc, State=#state{active_subpools=ActiveSubpools, subpool_records=SubpoolRecords, share_loggers=ActiveShareLoggers}) ->
    {ok, #configuration{active_subpools=CurrentSubpoolIds, share_loggers=ShareLoggers}} = ecoinpool_db:parse_configuration_document(Doc),
    
    % Remove deleted/changed share loggers
    lists:foreach(
        fun ({ShareLoggerId, _, _}) ->
            ecoinpool_share_broker:remove_sharelogger(ShareLoggerId)
        end,
        ActiveShareLoggers -- ShareLoggers
    ),
    % Add new/changed share loggers
    lists:foreach(
        fun ({ShareLoggerId, ShareLoggerType, ShareLoggerConfig}) ->
            ecoinpool_share_broker:add_sharelogger(ShareLoggerId, ShareLoggerType, ShareLoggerConfig)
        end,
        ShareLoggers -- ActiveShareLoggers
    ),
    
    ActiveSubpoolIds = sets:to_list(ActiveSubpools),
    
    State1 = State#state{current_subpools=sets:from_list(CurrentSubpoolIds), share_loggers=ShareLoggers},
    
    State2 = lists:foldl( % Add new sub-pools
        fun (SubpoolId, AccState) ->
            case dict:find(SubpoolId, SubpoolRecords) of
                {ok, Subpool} ->
                    reload_subpool(Subpool, AccState);
                _ ->
                    AccState % If we don't have the subpool record now, it has to follow later in the changes stream
            end
        end,
        State1,
        CurrentSubpoolIds -- ActiveSubpoolIds
    ),
    State3 = lists:foldl( % Remove deleted sub-pools
        fun (SubpoolId, AccState) ->
            remove_subpool(SubpoolId, false, AccState)
        end,
        State2,
        ActiveSubpoolIds -- CurrentSubpoolIds
    ),
    
    State3.

-spec reload_subpool(DocOrSubpool :: {[]} | subpool(), State :: #state{}) -> #state{}.
reload_subpool(Doc={_}, State=#state{subpool_records=SubpoolRecords}) ->
    case ecoinpool_db:parse_subpool_document(Doc) of
        {ok, Subpool=#subpool{id=SubpoolId}} ->
            % Store sub-pool and check if it has to be activated/reloaded
            reload_subpool(Subpool, State#state{subpool_records=dict:store(SubpoolId, Subpool, SubpoolRecords)});
        {error, invalid} ->
            log4erl:warn("ecoinpool_cfg_monitor: reload_subpool: Ignoring an invalid subpool document."),
            State
    end;
reload_subpool(Subpool=#subpool{id=SubpoolId}, State=#state{active_subpools=ActiveSubpools, current_subpools=CurrentSubpools}) ->
    % Check if sub-pool is already active
    case sets:is_element(SubpoolId, ActiveSubpools) of
        true -> % Yes: Reload the sub-pool, leave others as they are
            ecoinpool_sup:reload_subpool(Subpool),
            State;
        _ -> % No: Add new sub-pool, if we should
            case sets:is_element(SubpoolId, CurrentSubpools) of
                true ->
                    ecoinpool_sup:start_subpool(SubpoolId),
                    State#state{active_subpools=sets:add_element(SubpoolId, ActiveSubpools)};
                _ ->
                    State
            end
    end.

-spec remove_subpool(SubpoolId :: binary(), DeleteRecord :: boolean(), State :: #state{}) -> #state{}.
remove_subpool(SubpoolId, DeleteRecord, State=#state{active_subpools=ActiveSubpools, subpool_records=SubpoolRecords}) ->
    State1 = if
        DeleteRecord ->
            State#state{subpool_records=dict:erase(SubpoolId, SubpoolRecords)};
        true ->
            State
    end,
    case sets:is_element(SubpoolId, ActiveSubpools) of
        true ->
            ecoinpool_sup:stop_subpool(SubpoolId),
            State1#state{active_subpools=sets:del_element(SubpoolId, ActiveSubpools)};
        _ ->
            State1
    end.
