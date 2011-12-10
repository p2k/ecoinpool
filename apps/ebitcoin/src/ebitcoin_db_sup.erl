
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

-module(ebitcoin_db_sup).
-behaviour(supervisor).

-export([start_link/1, start_cfg_monitor/1]).

% Callbacks from supervisor
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(DBConfig) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [DBConfig]).

start_cfg_monitor(ConfDb) ->
    case supervisor:start_child(?MODULE, {ebitcoin_cfg_monitor, {ebitcoin_cfg_monitor, start_link, [ConfDb]}, permanent, 5000, worker, [ebitcoin_cfg_monitor]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        {error, {already_started, _}} -> ok;
        Error -> Error
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([DBConfig]) ->
    {ok, { {rest_for_one, 5, 10}, [
        {ebitcoin_db, {ebitcoin_db, start_link, [DBConfig]}, permanent, 5000, worker, [ebitcoin_db]}
    ]} }.
