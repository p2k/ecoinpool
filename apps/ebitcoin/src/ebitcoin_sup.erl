
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

-module(ebitcoin_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, running_clients/0, start_client/3, stop_client/1]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

running_clients() ->
    lists:foldl(
        fun (Spec, ClientNameAcc) ->
            case Spec of
                {ClientName, _, _, _} -> [ClientName | ClientNameAcc];
                _ -> ClientNameAcc
            end
        end,
        [],
        supervisor:which_children(?MODULE)
    ).

start_client(Name, PeerHost, PeerPort) ->
    case supervisor:start_child(?MODULE, {Name, {ebitcoin_client, start_link, [Name, PeerHost, PeerPort]}, transient, 5000, worker, [ebitcoin_client]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        Error -> Error
    end.

stop_client(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok -> supervisor:delete_child(?MODULE, Name);
        Error -> Error
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, [
    ]} }.
