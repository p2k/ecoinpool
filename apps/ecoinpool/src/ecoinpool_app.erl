
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

-module(ecoinpool_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    % Init hash library
    ok = ecoinpool_hash:init(),
    % Load configuration
    {ok, DBHost} = application:get_env(ecoinpool, db_host),
    {ok, DBPort} = application:get_env(ecoinpool, db_port),
    {ok, DBPrefix} = application:get_env(ecoinpool, db_prefix),
    {ok, DBOptions} = application:get_env(ecoinpool, db_options),
    % log4erl
    log4erl:conf(filename:join(code:priv_dir(ecoinpool), "log4erl.conf")),
    {ok, VSN} = application:get_key(ecoinpool, vsn),
    log4erl:warn("==> Welcome to ecoinpool v~s written by p2k! <==", [VSN]),
    ecoinpool_sup:start_link({DBHost, DBPort, DBPrefix, DBOptions}).

stop(_State) ->
    ok.
