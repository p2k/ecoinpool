
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

-module(ecoinpool_mysql_replicator_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    % Load configuration
    {ok, CouchDBHost} = application:get_env(ecoinpool_mysql_replicator, couchdb_host),
    {ok, CouchDBPort} = application:get_env(ecoinpool_mysql_replicator, couchdb_port),
    {ok, CouchDBPrefix} = application:get_env(ecoinpool_mysql_replicator, couchdb_prefix),
    {ok, CouchDBOptions} = application:get_env(ecoinpool_mysql_replicator, couchdb_options),
    {ok, CouchDBDatabase} = application:get_env(ecoinpool_mysql_replicator, couchdb_database),
    {ok, MySQLHost} = application:get_env(ecoinpool_mysql_replicator, mysql_host),
    {ok, MySQLPort} = application:get_env(ecoinpool_mysql_replicator, mysql_port),
    {ok, MySQLPrefix} = application:get_env(ecoinpool_mysql_replicator, mysql_prefix),
    {ok, MySQLOptions} = application:get_env(ecoinpool_mysql_replicator, mysql_options),
    {ok, MySQLDatabase} = application:get_env(ecoinpool_mysql_replicator, mysql_database),
    {ok, ReplicatorConfigs} = application:get_env(ecoinpool_mysql_replicator, replicator_configs),
    {ok, SharesConfigs} = application:get_env(ecoinpool_mysql_replicator, shares_configs),
    ecoinpool_mysql_replicator_sup:start_link(
        {CouchDBHost, CouchDBPort, CouchDBPrefix, CouchDBOptions, CouchDBDatabase},
        {MySQLHost, MySQLPort, MySQLPrefix, MySQLOptions, MySQLDatabase},
        ReplicatorConfigs,
        SharesConfigs
    ).

stop(_State) ->
    ok.
