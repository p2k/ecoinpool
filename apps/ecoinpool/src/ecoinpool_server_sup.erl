
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

-module(ecoinpool_server_sup).
-behaviour(supervisor).

-include("ecoinpool_misc_types.hrl").

-define(MakeSupRef(X), list_to_atom(lists:concat([?MODULE, '_', binary_to_list(X)]))).

-export([start_link/1, start_coindaemon/3, stop_coindaemon/1, add_auxdaemon/4, remove_auxdaemon/3]).

% Callbacks from supervisor
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

-spec start_link(SubpoolId :: binary()) -> {ok, pid()} | ignore | {error, {already_started, pid()} | shutdown | term()}.
start_link(SubpoolId) ->
    supervisor:start_link({global, ?MakeSupRef(SubpoolId)}, ?MODULE, [SubpoolId]).

-spec start_coindaemon(SubpoolId :: binary(), CoinDaemonModule :: module(), CoinDaemonConfig :: [conf_property()]) -> {ok, abstract_coindaemon()} | {error, term()}.
start_coindaemon(SubpoolId, CoinDaemonModule, CoinDaemonConfig) ->
    case supervisor:start_child({global, ?MakeSupRef(SubpoolId)}, {coindaemon, {CoinDaemonModule, start_link, [SubpoolId, CoinDaemonConfig]}, permanent, 5000, worker, [CoinDaemonModule]}) of
        {ok, PID} -> {ok, abstract_coindaemon:new(CoinDaemonModule, PID)};
        {ok, PID, _} -> {ok, abstract_coindaemon:new(CoinDaemonModule, PID)};
        {error, {already_started, PID}} -> {ok, abstract_coindaemon:new(CoinDaemonModule, PID)};
        Other -> Other
    end.

-spec stop_coindaemon(SubpoolId :: binary()) -> ok | {error, term()}.
stop_coindaemon(SubpoolId) ->
    SupRef = ?MakeSupRef(SubpoolId),
    case supervisor:terminate_child({global, SupRef}, coindaemon) of
        ok -> supervisor:delete_child({global, SupRef}, coindaemon);
        Error -> Error
    end.

-spec add_auxdaemon(SubpoolId :: binary(), AuxDaemonModule :: module(), AuxDaemonConfig :: [conf_property()], MMM :: mmm() | undefined) -> {ok, mmm()} | {error, term()}.
add_auxdaemon(SubpoolId, AuxDaemonModule, AuxDaemonConfig, MMM) ->
    Result = case supervisor:start_child({global, ?MakeSupRef(SubpoolId)}, {{auxdaemon, AuxDaemonModule}, {AuxDaemonModule, start_link, [SubpoolId, AuxDaemonConfig]}, permanent, 5000, worker, [AuxDaemonModule]}) of
        {ok, PID} -> {ok, PID};
        {ok, PID, _} -> {ok, PID};
        {error, {already_started, PID}} -> {ok, PID};
        Other -> Other
    end,
    case Result of
        {ok, ThePID} ->
            case MMM of
                undefined ->
                    {ok, ecoinpool_mmm:new([{AuxDaemonModule, ThePID}])};
                _ ->
                    {ok, MMM:add_aux_daemon(AuxDaemonModule, ThePID)}
            end;
        _ ->
            Result
    end.

-spec remove_auxdaemon(SubpoolId :: binary(), AuxDaemonModule :: module(), MMM :: mmm()) -> {ok, mmm()} | {error, term()}.
remove_auxdaemon(SubpoolId, AuxDaemonModule, MMM) ->
    SupRef = ?MakeSupRef(SubpoolId),
    case supervisor:terminate_child({global, SupRef}, {auxdaemon, AuxDaemonModule}) of
        ok ->
            supervisor:delete_child({global, SupRef}, {auxdaemon, AuxDaemonModule}),
            {ok, MMM:remove_aux_daemon(AuxDaemonModule)};
        Error ->
            Error
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([SubpoolId]) ->
    {ok, { {rest_for_one, 5, 10}, [
        {subpool, {ecoinpool_server, start_link, [SubpoolId]}, permanent, 5000, worker, [ecoinpool_server]}
    ]} }.
