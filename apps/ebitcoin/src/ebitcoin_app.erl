
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

-module(ebitcoin_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    % Init hash library
    ok = ecoinpool_hash:init(),
    % log4erl
    log4erl:conf(filename:join(code:priv_dir(ebitcoin), "log4erl.conf")),
    % Load configuration
    case application:get_env(ebitcoin, enabled) of
        {ok, true} ->
            {ok, DBHost} = application:get_env(ebitcoin, db_host),
            {ok, DBPort} = application:get_env(ebitcoin, db_port),
            {ok, DBPrefix} = application:get_env(ebitcoin, db_prefix),
            {ok, DBOptions} = application:get_env(ebitcoin, db_options),
            ebitcoin_sup:start_link({DBHost, DBPort, DBPrefix, DBOptions});
        _ ->
            log4erl:warn(ebitcoin, "The service has been disabled by configuration.")
    end.

stop(_State) ->
    ok.
