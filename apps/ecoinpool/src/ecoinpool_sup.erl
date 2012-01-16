
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

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

%% API
-export([
    start_link/2,
    running_subpools/0,
    start_subpool/1,
    reload_subpool/1,
    stop_subpool/1,
    start_mysql/5,
    stop_mysql/1,
    crash_store/2,
    crash_fetch/1,
    crash_repo_pid/0,
    crash_transfer_ets/1
]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(ServerId, DBConfig) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [ServerId, DBConfig]).

running_subpools() ->
    lists:foldl(
        fun (Spec, SubpoolIdAcc) ->
            case Spec of
                {{subpool, SubpoolId}, _, _, _} -> [SubpoolId | SubpoolIdAcc];
                _ -> SubpoolIdAcc
            end
        end,
        [],
        supervisor:which_children(?MODULE)
    ).

start_subpool(SubpoolId) ->
    case supervisor:start_child(?MODULE, {{subpool, SubpoolId}, {ecoinpool_server_sup, start_link, [SubpoolId]}, transient, 5000, supervisor, [ecoinpool_server_sup]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        Error -> Error
    end.

reload_subpool(Subpool) ->
    % Simple forwarding
    ecoinpool_server:reload_config(Subpool).

stop_subpool(SubpoolId) ->
    case supervisor:terminate_child(?MODULE, {subpool, SubpoolId}) of
        ok -> supervisor:delete_child(?MODULE, {subpool, SubpoolId});
        Error -> Error
    end.

start_mysql(MySQLHost, MySQLPort, MySQLUser, MySQLPassword, MySQLDatabase) ->
    PoolId = list_to_atom(lists:concat([MySQLHost, "_", MySQLDatabase, "_", MySQLUser])),
    LogFun = fun (_Module, _Line, Level, MsgFun) ->
        {Msg, Params} = MsgFun(),
        case Level of
            debug -> log4erl:debug(db, "~p:~n  " ++ Msg, [PoolId] ++ Params);
            normal -> log4erl:info(db, "~p:~n  " ++ Msg, [PoolId] ++ Params);
            warning -> log4erl:warn(db, "~p:~n  " ++ Msg, [PoolId] ++ Params);
            error -> log4erl:error(db, "~p:~n  " ++ Msg, [PoolId] ++ Params);
            _ -> ok
        end
    end,
    case supervisor:start_child(?MODULE, {{mysql, PoolId}, {mysql, start_link, [PoolId, MySQLHost, MySQLPort, MySQLUser, MySQLPassword, MySQLDatabase, LogFun]}, transient, 5000, worker, [mysql]}) of
        {ok, _} -> {ok, PoolId};
        {ok, _, _} -> {ok, PoolId};
        {error, {already_started, _}} -> {ok, PoolId};
        Error -> Error
    end.

stop_mysql(PoolId) ->
    case supervisor:terminate_child(?MODULE, {mysql, PoolId}) of
        ok -> supervisor:delete_child(?MODULE, {mysql, PoolId});
        Error -> Error
    end.

crash_store(Key, Value) ->
    ebitcoin_crash_repo:store(ecoinpool_crash_repo, Key, Value).

crash_fetch(Key) ->
    ebitcoin_crash_repo:fetch(ecoinpool_crash_repo, Key).

crash_repo_pid() ->
    whereis(ecoinpool_crash_repo).

crash_transfer_ets(Key) ->
    ebitcoin_crash_repo:transfer_ets(ecoinpool_crash_repo, Key).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([_ServerId, DBConfig]) ->
    {ok, { {one_for_one, 5, 10}, [
        {ecoinpool_crash_repo, {ebitcoin_crash_repo, start_link, [{local, ecoinpool_crash_repo}]}, permanent, 5000, worker, [ebitcoin_crash_repo]},
        {ecoinpool_rpc, {ecoinpool_rpc, start_link, []}, permanent, 5000, worker, [ecoinpool_rpc]},
        {ecoinpool_share_broker, {ecoinpool_share_broker, start_link, []}, permanent, 5000, worker, [ecoinpool_share_broker]},
        {ecoinpool_db, {ecoinpool_db_sup, start_link, [DBConfig]}, permanent, 5000, supervisor, [ecoinpool_db_sup]}
    ]} }.
