
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

-module(ecoinpool_mysql_replicator_sup).

-behaviour(supervisor).

-export([start_link/4]).

-export([init/1]).


start_link(CouchDbConfig, MySQLConfig, ReplicatorConfigs, ShareDeployerConfigs) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [CouchDbConfig, MySQLConfig, ReplicatorConfigs, ShareDeployerConfigs]).


init([{CouchDBHost, CouchDBPort, CouchDBPrefix, CouchDBOptions, CouchDBDatabase}, {MySQLHost, MySQLPort, MySQLPrefix, MySQLOptions, MySQLDatabase}, ReplicatorConfigs, ShareDeployerConfigs]) ->
    CouchServer = couchbeam:server_connection(CouchDBHost, CouchDBPort, CouchDBPrefix, CouchDBOptions),
    {ok, CouchDb} = couchbeam:open_db(CouchServer, CouchDBDatabase),
    {MySQLUser, MySQLPassword} = proplists:get_value(auth, MySQLOptions, {"root", ""}),
    
    Replicators = lists:map(
        fun ({SSubPoolId, MyTable, MyInterval}) ->
            if MyInterval =< 0 -> error(replicator_interval_zero_or_less); true -> ok end,
            SubPoolId = if is_binary(SSubPoolId) -> SSubPoolId; is_list(SSubPoolId) -> list_to_binary(SSubPoolId) end,
            {{replicator, SubPoolId, MyTable}, {mycouch_replicator, start_link, [
                CouchDb,
                {"workers/by_sub_pool", [{"sub_pool_id", SubPoolId}]},
                ecoinpool_mysql_replicator,
                MySQLPrefix ++ MyTable,
                ["associateduserid", "username", "password"],
                MyInterval,
                fun ecoinpool_couch_to_my/1,
                fun (MyProps) -> ecoinpool_my_to_couch(MyProps, SubPoolId) end
            ]}, permanent, 5000, worker, [mycouch_replicator]}
        end,
        ReplicatorConfigs
    ),
    
    ShareDeployers = lists:map(
        fun
            ({ConfigIdStr, PoolName, MyTable, MyInterval}) ->
                if MyInterval < 0 -> error(share_deploy_interval_less_than_zero); true -> ok end,
                {ok, MainPoolDb} = couchbeam:open_db(CouchServer, PoolName),
                {{share_deployer, ConfigIdStr}, {ecoinpool_mysql_share_deployer, start_link, [
                    ConfigIdStr,
                    CouchDb,
                    MainPoolDb,
                    ecoinpool_mysql_replicator,
                    MySQLPrefix ++ MyTable,
                    MyInterval
                ]}, permanent, 5000, worker, [ecoinpool_mysql_share_deployer]};
            ({ConfigIdStr, MainPoolName, AuxPoolName, MyTable, MyInterval}) ->
                if MyInterval < 0 -> error(share_deploy_interval_less_than_zero); true -> ok end,
                {ok, MainPoolDb} = couchbeam:open_db(CouchServer, MainPoolName),
                {ok, AuxPoolDb} = couchbeam:open_db(CouchServer, AuxPoolName),
                {{share_deployer, ConfigIdStr}, {ecoinpool_mysql_share_deployer, start_link, [
                    ConfigIdStr,
                    CouchDb,
                    MainPoolDb,
                    AuxPoolDb,
                    ecoinpool_mysql_replicator,
                    MySQLPrefix ++ MyTable,
                    MyInterval
                ]}, permanent, 5000, worker, [ecoinpool_mysql_share_deployer]}
        end,
        ShareDeployerConfigs
    ),
    
    {ok, { {one_for_one, 5, 10}, [
        {mysql, {mysql, start_link, [ecoinpool_mysql_replicator, MySQLHost, MySQLPort, MySQLUser, MySQLPassword, MySQLDatabase]}, permanent, 5000, worker, [mysql]}
    ] ++ Replicators ++ ShareDeployers} }.


ecoinpool_couch_to_my(CouchProps) ->
    [
        {"associateduserid", proplists:get_value(<<"user_id">>, CouchProps)},
        {"username", proplists:get_value(<<"name">>, CouchProps)},
        {"password", ecoinpool_util:parse_json_password(proplists:get_value(<<"pass">>, CouchProps))}
    ].

ecoinpool_my_to_couch(MyProps, SubPoolId) ->
    Name = proplists:get_value("username", MyProps),
    Pass = case proplists:get_value("password", MyProps) of
        undefined -> undefined;
        P -> ecoinpool_util:make_json_password(P, Name)
    end,
    [
        {<<"type">>, <<"worker">>},
        {<<"sub_pool_id">>, SubPoolId},
        {<<"user_id">>, proplists:get_value("associateduserid", MyProps)},
        {<<"name">>, Name},
        {<<"pass">>, Pass}
    ].
