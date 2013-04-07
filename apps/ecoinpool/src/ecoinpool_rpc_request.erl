
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

-include_lib("pmod_transform/include/pmod.hrl").

-module(ecoinpool_rpc_request, [ReqPID, Peer, Method, Params, Auth, MiningExtensions, LP]).

-export([get/1, has_params/0, check/0, start/2, ok/2, error/1]).

get(peer) ->
    Peer;
get(ip) ->
    element(1, Peer);
get(user_agent) ->
    element(2, Peer);
get(method) ->
    Method;
get(params) ->
    Params;
get(auth) ->
    Auth;
get(mining_extensions) ->
    MiningExtensions;
get(lp) ->
    LP.

has_params() ->
    case Params of
        [] -> false;
        _ -> true
    end.

check() ->
    % Explicitly check for connection drops
    case process_info(ReqPID, status) of
        undefined -> error;
        _ -> ok
    end.

start(WithHeartbeat, Options) ->
    ReqPID ! {start, WithHeartbeat, Options}, ok.

ok(Result, Options) ->
    ReqPID ! {ok, Result, Options}, ok.

error(Type) ->
    ReqPID ! {error, Type}, ok.
