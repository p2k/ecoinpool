
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

-module(ecoinpool_sup).

-behaviour(supervisor).

%% API
-export([start_link/1, start_cfg_monitor/1, stop_cfg_monitor/0, start_coindaemon/6, stop_coindaemon/2]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(DBConfig) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [DBConfig]).

start_cfg_monitor(ConfDb) ->
    case supervisor:start_child(?MODULE, {ecoinpool_cfg_monitor, {ecoinpool_cfg_monitor, start_link, [ConfDb]}, transient, 5000, worker, [ecoinpool_cfg_monitor]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        Error -> Error
    end.

stop_cfg_monitor() ->
    case supervisor:terminate_child(?MODULE, ecoinpool_cfg_monitor) of
        ok -> supervisor:delete_child(?MODULE, ecoinpool_cfg_monitor);
        Error -> Error
    end.

start_coindaemon(CoinDaemonModule, Id, Host, Port, User, Pass) ->
    case supervisor:start_child(?MODULE, {{CoinDaemonModule, Id}, {CoinDaemonModule, start_link, [Host, Port, User, Pass]}, transient, 5000, worker, [CoinDaemonModule]}) of
        {ok, Pid, _} -> {ok, Pid};
        Other -> Other
    end.

stop_coindaemon(CoinDaemonModule, Id) ->
    case supervisor:terminate_child(?MODULE, {CoinDaemonModule, Id}) of
        ok -> supervisor:delete_child(?MODULE, {CoinDaemonModule, Id});
        Error -> Error
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([DBConfig]) ->
    {ok, { {one_for_one, 5, 10}, [
        ?CHILD(ecoinpool_rpc, worker),
        {ecoinpool_db, {ecoinpool_db, start_link, [DBConfig]}, permanent, 5000, worker, [ecoinpool_db]}
    ]} }.
