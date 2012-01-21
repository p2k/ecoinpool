
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

-module(ecoinpool_sharelogger_sup).

-behaviour(supervisor).

-include("ecoinpool_misc_types.hrl").
-include("ecoinpool_db_records.hrl").

-export([
    start_link/0,
    start_sharelogger/3,
    running_shareloggers/0,
    stop_sharelogger/1
]).

-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_sharelogger(LoggerId :: atom(), Module :: module(), Config :: [conf_property()]) -> ok | {error, term()}.
start_sharelogger(LoggerId, Module, Config) ->
    log4erl:info("Starting share logger ~p (~p).", [LoggerId, Module]),
    case supervisor:start_child(?MODULE, {{sharelogger, LoggerId}, {Module, start_link, [LoggerId, Config]}, permanent, 15000, worker, [Module]}) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        Error -> Error
    end.

-spec running_shareloggers() -> [{LoggerId :: atom(), Module :: module()}].
running_shareloggers() ->
    [{LoggerId, Module} || {{sharelogger, LoggerId}, _, _, [Module]} <- supervisor:which_children(?MODULE)].

-spec stop_sharelogger(LoggerId :: atom()) -> ok | {error, term()}.
stop_sharelogger(LoggerId) ->
    log4erl:info("Stopping share logger ~p.", [LoggerId]),
    case supervisor:terminate_child(?MODULE, {sharelogger, LoggerId}) of
        ok -> supervisor:delete_child(?MODULE, {sharelogger, LoggerId});
        Error -> Error
    end.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, [
        {ecoinpool_share_broker, {ecoinpool_share_broker, start_link, []}, permanent, 5000, worker, [ecoinpool_share_broker]}
    ]} }.
