
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

-module(ecoinpool_db_sup).
-behaviour(supervisor).

-export([start_link/1, start_cfg_monitor/1, start_worker_monitor/1]).

% Callbacks from supervisor
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(DBConfig) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [DBConfig]).

start_cfg_monitor(ConfDb) ->
    case supervisor:start_child(?MODULE, {ecoinpool_cfg_monitor, {ecoinpool_cfg_monitor, start_link, [ConfDb]}, permanent, 5000, worker, [ecoinpool_cfg_monitor]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        Error -> Error
    end.

start_worker_monitor(ConfDb) ->
    case supervisor:start_child(?MODULE, {ecoinpool_worker_monitor, {ecoinpool_worker_monitor, start_link, [ConfDb]}, permanent, 5000, worker, [ecoinpool_worker_monitor]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        Error -> Error
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([DBConfig]) ->
    {ok, { {rest_for_one, 5, 10}, [
        {ecoinpool_db, {ecoinpool_db, start_link, [DBConfig]}, permanent, 5000, worker, [ecoinpool_db]}
    ]} }.
