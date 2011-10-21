
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

-include("ecoinpool_db_records.hrl").

%% API
-export([start_link/1, start_cfg_monitor/1, stop_cfg_monitor/0, start_subpool/1, stop_subpool/1]).

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

start_subpool(Subpool=#subpool{id=Id}) ->
    case supervisor:start_child(?MODULE, {{subpool, Id}, {ecoinpool_server_sup, start_link, [Subpool]}, transient, 5000, supervisor, [ecoinpool_server]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        Error -> Error
    end.

stop_subpool(Id) ->
    case supervisor:terminate_child(?MODULE, {subpool, Id}) of
        ok -> supervisor:delete_child(?MODULE, {subpool, Id});
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
