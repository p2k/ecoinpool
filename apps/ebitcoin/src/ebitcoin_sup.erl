
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
-export([
    start_link/1,
    running_clients/0,
    start_client/3,
    stop_client/1,
    crash_store/2,
    crash_fetch/1,
    crash_transfer_ets/1
]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(DBConfig) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [DBConfig]).

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

crash_store(Key, Value) ->
    ebitcoin_crash_repo:store(ebitcoin_crash_repo, Key, Value).

crash_fetch(Key) ->
    ebitcoin_crash_repo:fetch(ebitcoin_crash_repo, Key).

crash_transfer_ets(Key) ->
    ebitcoin_crash_repo:transfer_ets(ebitcoin_crash_repo, Key).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([DBConfig]) ->
    {ok, { {one_for_one, 5, 10}, [
        {ebitcoin_crash_repo, {ebitcoin_crash_repo, start_link, [{local, ebitcoin_crash_repo}]}, permanent, 5000, worker, [ebitcoin_crash_repo]},
        {ebitcoin_db, {ebitcoin_db_sup, start_link, [DBConfig]}, permanent, 5000, supervisor, [ebitcoin_db_sup]}
    ]} }.
