
%%
%% Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
%%
%% This file is part of ebitcoin.
%%
%% ebitcoin is free software: you can redistribute it and/or modify
%% it under the terms of the GNU General Public License as published by
%% the Free Software Foundation, either version 3 of the License, or
%% (at your option) any later version.
%%
%% ebitcoin is distributed in the hope that it will be useful,
%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%% GNU General Public License for more details.
%%
%% You should have received a copy of the GNU General Public License
%% along with ebitcoin.  If not, see <http://www.gnu.org/licenses/>.
%%

-module(ebitcoin_cfg_monitor).
-behaviour(gen_changes).

-include("ebitcoin_db_records.hrl").

-export([start_link/1]).

-export([init/1, handle_change/2, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ConfDb) ->
    gen_changes:start_link(?MODULE, ConfDb, [continuous, heartbeat, {filter, "doctypes/clients_only"}], []).

%% ===================================================================
%% Gen_Changes callbacks
%% ===================================================================

init([]) ->
    % Get already running clients; useful if we were restarted
    ActiveClientIds = ebitcoin_sup:running_clients(),
    {ok, sets:from_list(ActiveClientIds)}.

handle_change({ChangeProps}, CurrentClients) ->
    case proplists:get_value(<<"id">>, ChangeProps) of
        <<"configuration">> -> % The one and only root config document
            gen_changes:cast(self(), reload_root_config); % Schedule root config reload
        OtherId ->
            case sets:is_element(OtherId, CurrentClients) of
                true ->
                    gen_changes:cast(self(), {reload_client, OtherId});
                _ ->
                    ok
            end
    end,
    {noreply, CurrentClients}.

handle_call(_Message, _From, CurrentClients) ->
    {reply, error, CurrentClients}.

handle_cast(reload_root_config, CurrentClients) ->
    % Load the root configuration, crash on error
    {ok, #configuration{active_clients=ActiveClientIds, view_update_interval=ViewUpdateInterval}} = ebitcoin_db:get_configuration(),
    
    % Set the view update interval
    ebitcoin_db:set_view_update_interval(ViewUpdateInterval),
    
    CurrentClientIds = sets:to_list(CurrentClients),
    
    lists:foreach( % Add new clients
        fun (ClientId) ->
            gen_changes:cast(self(), {reload_client, ClientId})
        end,
        ActiveClientIds -- CurrentClientIds
    ),
    lists:foreach( % Remove deleted clients
        fun (ClientId) ->
            gen_changes:cast(self(), {remove_client, ClientId})
        end,
        CurrentClientIds -- ActiveClientIds
    ),
    
    {noreply, CurrentClients};

handle_cast({reload_client, ClientId}, CurrentClients) ->
    % Load the client configuration (here to check if valid)
    case ebitcoin_db:get_client_record(ClientId) of
        {ok, Client} ->
            % Check if client is already there
            case sets:is_element(ClientId, CurrentClients) of
                true -> % Yes: Reload the client, leave others as they are
                    ebitcoin_sup:reload_client(Client);
                _ -> % No: Add new client
                    ebitcoin_sup:start_client(ClientId)
            end,
            % Add (if not already there)
            {noreply, sets:add_element(ClientId, CurrentClients)};
        
        {error, missing} -> % Stop if missing
            case sets:is_element(ClientId, CurrentClients) of
                true ->
                    ebitcoin_sup:stop_client(ClientId),
                    {noreply, sets:del_element(ClientId, CurrentClients)};
                _ ->
                    {noreply, CurrentClients}
            end;
        
        {error, invalid} -> % Ignore on invalid
            log4erl:warn(ebitcoin, "ebitcoin_cfg_monitor: reload_client: Invalid document for client ID: ~s.", [ClientId]),
            {noreply, CurrentClients}
    end;

handle_cast({remove_client, ClientId}, CurrentClients) ->
    case sets:is_element(ClientId, CurrentClients) of
        true ->
            ebitcoin_sup:stop_client(ClientId),
            {noreply, sets:del_element(ClientId, CurrentClients)};
        _ ->
            {noreply, CurrentClients}
    end;

handle_cast(_Message, CurrentClients) ->
    {noreply, CurrentClients}.

handle_info(_Message, CurrentClients) ->
    {noreply, CurrentClients}.

terminate(_Reason, _CurrentClients) ->
    ok.
