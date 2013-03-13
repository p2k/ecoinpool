
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

-module(remote_sharelogger).
-behaviour(gen_sharelogger).
-behaviour(gen_server).

-include("gen_sharelogger_spec.hrl").

-export([start_link/2, log_share/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(LoggerId, Config) ->
    gen_server:start_link({local, LoggerId}, ?MODULE, Config, []).

log_share(LoggerId, Share) ->
    gen_server:cast(LoggerId, Share).

%% ===================================================================
%% Gen_Server callbacks
%% ===================================================================

init(Config) ->
    RegName = binary_to_atom(proplists:get_value(registered_name, Config), utf8),
    case proplists:get_value(node, Config) of
        undefined -> ok;
        Node -> pong = net_adm:ping(binary_to_atom(Node, utf8))
    end,
    UseGenServer = proplists:get_value(use_gen_server, Config, true),
    {ok, MyServerId} = application:get_env(ecoinpool, server_id),
    {ok, {RegName, MyServerId, UseGenServer}}.

handle_call(_, _From, State) ->
    {reply, error, State}.

handle_cast(Share=#share{server_id=local}, State={RegName, MyServerId, UseGenServer}) ->
    if
        UseGenServer ->
            gen_server:cast({global, RegName}, Share#share{server_id=MyServerId});
        true ->
            global:send(RegName, Share#share{server_id=MyServerId})
    end,
    {noreply, State};
handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
